package App::DuckPAN::Web;
# ABSTRACT: Webserver for duckpan server

use Moo;
use DDG::Request;
use DDG::Test::Location;
use DDG::Test::Language;
use Path::Tiny;
use Plack::Request;
use Plack::Response;
use Plack::MIME;
use HTML::Entities;
use HTML::TreeBuilder;
use HTML::Element;
use Data::Printer;
use HTTP::Request;
use LWP::UserAgent;
use URI::Escape;
use JSON;
use Data::Dumper;

has blocks => ( is => 'ro', required => 1 );
has page_root => ( is => 'ro', required => 1 );
has page_spice => ( is => 'ro', required => 1 );
has page_css => ( is => 'ro', required => 1 );
has page_js => ( is => 'ro', required => 1 );
has page_locales => ( is => 'ro', required => 1 );
has page_templates => ( is => 'ro', required => 1 );
has server_hostname => ( is => 'ro', required => 0 );

has _our_hostname => ( is => 'rw' );
has _share_dir_hash => ( is => 'rw' );
has _path_hash => ( is => 'rw' );
has _rewrite_hash => ( is => 'rw' );

has ua => (
	is => 'ro',
	default => sub {
		LWP::UserAgent->new(
			agent => "Mozilla/5.0", #User Agent required for some API's (eg. Vimeo, IsItUp)
			timeout => 5,
			ssl_opts => { verify_hostname => 0 },
			env_proxy => 1,
		);
	},
);

sub BUILD {
	my ( $self ) = @_;
	my %share_dir_hash;
	my %path_hash;
	my %rewrite_hash;
	for (@{$self->blocks}) {
		for (@{$_->only_plugin_objs}) {
			if ($_->does('DDG::IsSpice')) {
				$rewrite_hash{ref $_} = $_->rewrite if $_->has_rewrite;
			}
			$share_dir_hash{$_->module_share_dir} = ref $_ if $_->can('module_share_dir');
			$path_hash{$_->path} = ref $_ if $_->can('path');
		}
	}
	$self->_share_dir_hash(\%share_dir_hash);
	$self->_path_hash(\%path_hash);
	$self->_rewrite_hash(\%rewrite_hash);
}

sub run_psgi {
	my ( $self, $env ) = @_;
	$self->_our_hostname($env->{HTTP_HOST}) unless $self->_our_hostname;
	my $request = Plack::Request->new($env);
	my $response = $self->request($request);
	return $response->finalize;
}

my $has_common_js = 0;
sub request {
	my ( $self, $request ) = @_;
	my $hostname = $self->server_hostname;
	my @path_parts = split(/\/+/,$request->request_uri);
	shift @path_parts;
	my $response = Plack::Response->new(200);
	my $body;

	if ($request->request_uri eq "/"){
		$response->content_type("text/html");
		$body = $self->page_root;
	} elsif (@path_parts && $path_parts[0] eq 'share') {
		my $share_dir;
		for (keys %{$self->_share_dir_hash}) {
			if ($request->path =~ m|^/$_|g) {

				$share_dir = $_;
				my $filename = pop @path_parts;
				my $remainder = $request->path;
				$remainder =~ s|$share_dir||;
				$remainder =~ s|$filename||;
				$remainder =~ s|//|/|;
				$remainder =~ s|^/\d{3,4}||;

				$filename = $remainder . $filename if $remainder;

				if (my $filename_path = $self->_share_dir_hash->{$share_dir}->can('share')->($filename)) {

					my $content_type = Plack::MIME->mime_type($filename);
					$response->content_type($content_type);

					if ($filename =~ /\.js$/ && $has_common_js &&
						$request->path =~ /(share\/spice\/([^\/]+)\/?)(.*)/){

						my $parent_dir = $1;
						my $parent_name = $2;
						my $common_js = $parent_dir."$parent_name.js";

						$body = path($common_js)->slurp;
						print "\nAppended $common_js to $filename\n\n";
					}

					$body .= path($filename_path)->slurp;
				} else {
					$share_dir = undef;
				}
			}
		}
		unless ($share_dir){
			$response->status(404);
			my $path = join "/", @path_parts;
			my $errormsg = "ERROR: File not found - $path";
			print "\n" . $errormsg . "\n";
			$body = $errormsg;
		}
	} elsif (@path_parts && $path_parts[0] eq 'js' && $path_parts[1] eq 'spice') {
		my $rewrite;
		for (keys %{$self->_path_hash}) {
			if ($request->request_uri =~ m/^$_/g) {
				my $path_remainder = $request->request_uri;
				$path_remainder =~ s/^$_//;
				$path_remainder =~ s/\/+/\//g;
				$path_remainder =~ s/^\///;
				my $spice_class = $self->_path_hash->{$_};
				$rewrite = $self->_rewrite_hash->{$spice_class};
				die "Spice tested here must have a rewrite..." unless $rewrite;
				my $from = $rewrite->from;
				my $re = $rewrite->has_from ? qr{$from} : qr{(.*)};
				if (my @captures = $path_remainder =~ m/$re/) {
					my $to = $rewrite->parsed_to;
					for (1..@captures) {
						my $index = $_-1;
						my $cap_from = '\$'.$_;
						my $cap_to = $captures[$index];
						if (defined $cap_to) {
							$to =~ s/$cap_from/$cap_to/g;
						} else {
							$to =~ s/$cap_from//g;
						}
					}
					# Make sure we replace "${dollar}" with "$".
					$to =~ s/\$\{dollar\}/\$/g;

					# Check if environment variables (most likely the API key) is missing.
					# If it is missing, switch to the DDG endpoint.
					if(defined $rewrite->missing_envs) {
						 $to = 'https://ddh1.duckduckgo.com' . $request->request_uri;
						 # Display the URL that we used.
						 print "\nAPI key not found. Using DuckDuckGo's endpoint:\n";
					}
					p($to);

					my $res = $self->ua->request(HTTP::Request->new(
						GET => $to,
						[ $rewrite->accept_header ? ("Accept", $rewrite->accept_header) : () ]
						));
					if ($res->is_success) {
						$body = $res->decoded_content;
						# Encode utf8 api_responses to bytestream for Plack.
						utf8::encode $body if utf8::is_utf8 $body;
						warn "Cannot use wrap_jsonp_callback and wrap_string callback at the same time!" if $rewrite->wrap_jsonp_callback && $rewrite->wrap_string_callback;
						if ($rewrite->wrap_jsonp_callback && $rewrite->callback) {
							$body = $rewrite->callback.'('.$body.');' unless defined $rewrite->missing_envs;
						}
						elsif ($rewrite->wrap_string_callback && $rewrite->callback) {
							$body =~ s/"/\\"/g;
							$body =~ s/\n/\\n/g;
							$body =~ s/\R//g;
							$body = $rewrite->callback.'("'.$body.'");' unless defined $rewrite->missing_envs;
						}
						$response->code($res->code);
						$response->content_type($res->content_type);
					} else {
						p($res->status_line, color => { string => 'red' });
						my $errormsg = (pop @{[split'::', $spice_class]}). ": ".$res->status_line;
						$body = '$("#message").removeClass("is-hidden").append("<div class=\"msg msg--warning\">'. $errormsg .'</div>");';
					}
				}
			}
		}
		unless ($rewrite){
			$response->status(404);
			my $path = join "/", @path_parts;
			my $errormsg = "ERROR: Rewrite not found - $path";
			print "\n" . $errormsg . "\n";
			$body = $errormsg;
		}
	} elsif ($request->param('duckduckhack_ignore')) {
		$response->status(204);
		$body = "";
	} elsif ($request->param('duckduckhack_css')) {
		$response->content_type('text/css');
		$body = $self->page_css;
	} elsif ($request->param('duckduckhack_js')) {
		$response->content_type('text/javascript');
		$body = $self->page_js;
	} elsif ($request->param('duckduckhack_locales')) {
		$response->content_type('text/javascript');
		$body = $self->page_locales;
	} elsif ($request->param('duckduckhack_templates')) {
		$response->content_type('text/javascript');
		$body = $self->page_templates;
	} elsif ($request->param('q') && $request->path_info eq '/') {
		my $query = $request->param('q');
		$query =~ s/^\s+|\s+$//g; # strip leading & trailing whitespace
		Encode::_utf8_on($query);
		my $ddg_request = DDG::Request->new(
			query_raw => $query,
			location => test_location_by_env(),
			language => test_language_by_env(),
		);

		my @results = ();
		my @calls_nrj = ();
		my @calls_nrc = ();
		my @calls_script = ();
		my %calls_template = ();
		my @calls_goodie;

		for (@{$self->blocks}) {
			push(@results,$_->request($ddg_request));
		}

		my $page = $self->page_spice;
		my $uri_encoded_query = uri_escape_utf8($query, "^A-Za-z");
		my $html_encoded_query = encode_entities($query);
		my $uri_encoded_ddh = quotemeta(uri_escape('duckduckhack-template-for-spice2', "^A-Za-z0-9"));
		$page =~ s/duckduckhack-template-for-spice2/$html_encoded_query/g;
		$page =~ s/$uri_encoded_ddh/$uri_encoded_query/g;

		# For debugging query replacement.
		#p($uri_encoded_ddh);
		#p($page);

		my $root = HTML::TreeBuilder->new;
		$root->parse($page);

		# Check for no results
		if (!scalar(@results)) {
			my $error = "Sorry, no hit for your instant answer";
			$root = HTML::TreeBuilder->new;
			$root->parse($self->page_root);
			my $text_field = $root->look_down(
				"name", "q"
			);
			$text_field->attr( value => $query );
			$root->find_by_tag_name('body')->push_content(
				HTML::TreeBuilder->new_from_content("<script type=\"text/javascript\">seterr('$error')</script>")->guts
			);
			p($error, color => { string => 'red' });
		}

		# Iterate over results,
		# checking if result is a Spice or Goodie
		# and sets up the page content accordingly
		foreach my $result (@results) {

			# Info for terminal.
			p($result) if $result;

			# NOTE -- this isn't designed to have both goodies and spice at once.

			my $res_ref = ref $result;
			my $result_type =	($res_ref eq 'DDG::ZeroClickInfo::Spice') ? 'spice' :
								($res_ref eq 'DDG::ZeroClickInfo') ?		'goodie' :
																			'other';
			my $is_goodie = $result_type eq 'goodie';
			if (($result_type eq 'spice' || $is_goodie)
				&& $result->caller->can('module_share_dir')) {
				# grab associated JS, Handlebars and CSS
				# and add them to correct arrays for injection into page
				my $share_dir = path($result->caller->module_share_dir);
				my @path = split(/\/+/, $share_dir);
				my $ia_name = join("_", @path[2..$#path]);

				foreach ($share_dir->children) {
					my $name = $_->basename;
					if ($name =~ /$ia_name\.js$/){
						push (@calls_script, $_);

					} elsif ($name =~ /$ia_name\.css$/){
						push (@calls_nrc, $_);

					} elsif ($name =~ /handlebars$/){
						$name =~ s/\.handlebars//;
						$calls_template{$ia_name}{$name}{"content"} = $_;
						$calls_template{$ia_name}{$name}{"is_ct_self"} = $is_goodie ? 1 : $result->call_type eq 'self';
					}
				}
				push (@calls_nrj, $result->call_path) if ($result->can('call_path'));
			}
			if ($is_goodie){
				# We have a Goodie result so modify HTML and return content
				# Grab ZCI div, push in required HTML
				my $zci_container = HTML::Element->new('div', id => "zci-answer", class => "zci zci--answer is-active");
				if ($result->has_structured_answer) {
					# Inject a script which prints out what we want.
					# There is no error-checking or support for non-auto-templates here.
					my $structured = $result->structured_answer;
					if(exists $structured->{templates}){ # user-specified templates
						push @calls_goodie, $structured;
						last;
					}
					else{ # auto-template
						my $template_name = 'goodie_'.scalar @{$structured->{input}}.'_inputs';
						my $json_string = encode_json({Answer => $structured});
						$zci_container->push_content(HTML::TreeBuilder->new_from_content("<script>\$(window).load(function(){"
							. "document.getElementById('zci-answer').innerHTML = DDG.exec_template('$template_name', $json_string);"
							. "});</script>")->guts);
					}
				} else {
					$zci_container->push_content(
						HTML::TreeBuilder->new_from_content(
							q(<div class="cw">
								<div class="zci__main  zci__main--detail">
									<div class="zci__body"></div>
								</div>
							</div>)
						)->guts
					);
					my $zci_body = $zci_container->look_down(class => 'zci__body');

					# Stick the answer inside $zci_body
					my $answer = $result->answer;
					if ($result->has_html) {
						my $tb = HTML::TreeBuilder->new();
						# Specifically allow unknown tags to support <svg> and <canvas>
						$tb->ignore_unknown(0);
						# Allow empty tags
                                                $tb->empty_element_tags(1);
						$answer = $tb->parse_content($result->html)->guts;
					}
					$zci_body->push_content($answer);
				}

				my $zci_wrapper = $root->look_down(id => "zero_click_wrapper");
				$zci_wrapper->insert_element($zci_container);

				my $duckbar_home = $root->look_down(id => "duckbar_home");
				$duckbar_home->delete_content();
				$duckbar_home->attr(class => "zcm__menu");
				$duckbar_home->push_content(
					HTML::TreeBuilder->new_from_content(
						q(<li class="zcm__item">
							<a data-zci-link="answer" class="zcm__link  zcm__link--answer is-active" href="javascript:;">Answer</a>
						</li>)
					)->guts
				);

				my $duckbar_static_sep = $root->look_down(id => "duckbar_static_sep");
				$duckbar_static_sep->attr(class => "zcm__sep--h");

				my $html = $root->look_down(_tag => "html");
				$html->attr(class => "set-header--fixed  has-zcm js no-touch csstransforms3d csstransitions svg use-opts has-active-zci");

				# Make sure we only show one Goodie (this will change down the road)
				last;
			}
			if ($result_type eq 'other') {
				# Not Spice or Goodie, inject raw Dumper() output from into page

				my $content = $root->look_down(id => "bottom_spacing2");
				my $dump = HTML::Element->new('pre');
				$dump->push_content(Dumper $result);
				$content->insert_element($dump);
				$page = $root->as_HTML;
			}
		}

		# Setup various script tags for IAs that can template:
		#   calls_script : js files
		#   calls_nrj : proxied spice api calls or goodie future
		#   calls_nrc : css calls
		#   calls_template : handlebars templates

		my $calls_nrj;
		my $calls_script = join('', map { q|<script type='text/JavaScript' src='| . $_ . q|'></script>| } @calls_script);
		# For now we only allow a single goodie. If that changes, we will do the
		# same join/map as with spices.
		if(@calls_goodie){
			my $goodie = shift @calls_goodie;
			$calls_nrj = "DDG.duckbar.future_signal_tab({signal:'high',from:'$goodie->{id}'});",
			# Uncomment following line and remove "setTimeout" line when javascript race condition is addressed
			# $calls_script = q|<script type="text/JavaScript" class="script-run-on-ready">/*DDH.add(| . encode_json($goodie) . q|);*/</script>|;
			$calls_script .= q|<script type="text/JavaScript" class="script-run-on-ready">/*window.setTimeout(DDH.add.bind(DDH, | . encode_json($goodie) . q|), 100);*/</script>|;
		}
		else{
			$calls_nrj = @calls_nrj ? join(';', map { "nrj('".$_."')" } @calls_nrj) . ';' : '';
		}
		my $calls_nrc = @calls_nrc ? join(';', map { "nrc('".$_."')" } @calls_nrc) . ';' : '';

		if (%calls_template) {
			foreach my $spice_name ( keys %calls_template ){
				$calls_script .= join("",map {
					my $template_name = $_;
					my $is_ct_self = $calls_template{$spice_name}{$template_name}{"is_ct_self"};
					my $template_content = $calls_template{$spice_name}{$template_name}{"content"}->slurp;
					"<script class='duckduckhack_spice_template' spice-name='$spice_name' template-name='$template_name' is-ct-self='$is_ct_self' type='text/plain'>$template_content</script>"

				} keys %{ $calls_template{$spice_name} });
			}
		}


		inject_mock_content($root);

		$page = $root->as_HTML;

		$page =~ s/####DUCKDUCKHACK-CALL-NRJ####/$calls_nrj/g;
		$page =~ s/####DUCKDUCKHACK-CALL-NRC####/$calls_nrc/g;
		$page =~ s/####DUCKDUCKHACK-CALL-SCRIPT####/$calls_script/g;

		$response->content_type('text/html');
		$body = $page;

	} else {
		my $res = $self->ua->request(HTTP::Request->new(GET => "http://".$hostname.$request->request_uri));
		if ($res->is_success) {
			$body = $res->decoded_content;
			$response->code($res->code);
			$response->content_type($res->content_type);
		} else {
			p($res->status_line, color => { string => 'red' });
			$body = "";
		}
	}

	$response->body($body);
	return $response;
}


#inject some mock results into the SERP to make it look a little more real
sub inject_mock_content {

	my $root= shift;

	# ensure results and ad containers exist
	my $ad_container = $root->look_down(id => "ads");
	my $links_container = $root->look_down(id => "links");
	return unless $ad_container && $links_container;

	#inject a mock ad into the page
	$ad_container->attr("style", "display: block");

	$ad_container->push_content(
		HTML::TreeBuilder->new_from_content(
			q(<div id="ra-0" class="result results_links highlight_a  result--ad  highlight_sponsored  sponsored highlight highlight_sponsored_hover" data-nir="1">
				<div class="result__body links_main links_deep">
					<a href="#" class="result__badge  badge--ad">Ad</a>
					<h2 class="result__title">
					<a class="result__a" href="#">Lorem ipsum Culpa ex adipisicing.</a>
					<a class="result__check" href="#">
						<span class="result__check__tt">Lorem ipsum Consectetur nostrud id quis in ut.</span>
					</a>
					</h2>
					<div class="result__snippet">
						<a href="#">Lorem ipsum Nisi aute velit sit dolore sit amet fugiat consequat aute reprehenderit in dolore deserunt.</a>
					</div>
					<div class="result__extras">
						<div class="result__extras__url">
							<a class="result__url" href="#">duckduckgo.com</a>
						</div>
					</div>
				</div>
			</div>)
		)->guts
	);

	#inject some mock ad into the page
	for (1..4){
		$links_container->push_content(
			HTML::TreeBuilder->new_from_content(
				q(<div id="r$_-0" class="result results_links_deep " data-nir="$_"
					<div class="result__body links_main links_deep">
						<h2 class="result__title">
						<a class="result__a" href="#">
							Lorem ipsum Duis elit voluptate in ut sed culpa nostrud sint est occaecat in irure veniam exercitation
						</a>
						<a class="result__check" href="#">
							<span class="result__check__tt">Your browser indicates if you've visited this link</span>
						</a>
						</h2>
						<div class="result__snippet">
							Lorem ipsum Mollit ut voluptate in id laborum nulla adipisicing ad ea do do nisi nulla qui quis do nisi pariatur voluptate minim dolore enim commodo cillum ullamco pariatur culpa.
						</div>
						<div class="result__extras">
							<div class="result__extras__url">
								<span class="result__icon">
								<a href="#">
									<img title="Search www.duckduckgo.com" id="i101" height="16" width="16" class="result__icon__img" src="//icons.duckduckgo.com/ip2/www.duckduckgo.com.ico">
								</a>
								</span>
								<a class="result__url" href="#">
									<span class="result__url__domain">Lorem.ipsum.com</span>
									<span class="result__url__full">/Incididunt%20reprehenderit%20ullamco.</span>
								</a>
							</div>
							<a href="#">More results</a>
						</div>
					</div>
				</div>)
			)->guts
		);
	}
}

1;
