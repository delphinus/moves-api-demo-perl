use common::sense;
use Amon2::Lite;
use Data::Util qw!:check!;
use Date::Manip;
use DBI;
use FindBin;
use JSON;
use Log::Minimal;
use Path::Class;
use Plack::Session::Store::DBI;

use lib "$ENV{HOME}/git/perl-Net-Moves/lib";
use Net::Moves;

our $BASE_DIR;
BEGIN { $BASE_DIR = dir($FindBin::Bin); }
use lib $BASE_DIR->subdir(qw!extlib lib perl5!)->stringify;
use lib $BASE_DIR->subdir('lib')->stringify;


our $VERSION = '0.01';

our $MOVES_CALLBACK_PATH = '/auth/moves/callback';

# put your configuration here
sub load_config {
    my $c = shift;

    my $mode = $c->mode_name || 'development';
    my $db_path = $BASE_DIR->file(lc("db/$mode.db"));
    $db_path->parent->mkpath unless -d $db_path->parent;

    +{
        'Text::Xslate' => +{
            function => +{
                UnixDate => sub { UnixDate @_; },
            },
        },
        DBI => [
            "dbi:SQLite:dbname=$db_path",
            '',
            '',
        ],
        site => +{
            client_id => $ENV{MOVES_CLIENT_ID},
            client_secret => $ENV{MOVES_CLIENT_SECRET},
            site => 'https://api.moves-app.com',
            authorize_path => 'moves://app/authorize',
            authorize_path_for_pc => 'https://api.moves-app.com/oauth/v1/authorize',
            access_token_path => 'https://api.moves-app.com/oauth/v1/access_token',
        },
    }
}

{
    my $dbh;

    sub get_dbh { #{{{
        return $dbh if defined $dbh;

        my $config = __PACKAGE__->config;
        $dbh = DBI->connect(@{$config->{DBI}});
        my $driver_name = $dbh->{Driver}{Name};
        my $fname = $BASE_DIR->file(lc("sql/$driver_name.sql"));
        my $sql = $fname->slurp or die "$fname: $!";
        for my $stmt (split /;/, $sql) {
            next unless $stmt =~ /\S/;
            $dbh->do($stmt) or die $dbh->errstr;
        }

        return $dbh;
    } #}}}
}

get '/' => sub { my $c = shift; #{{{
    if ($c->session->get('access_token')) {
        return $c->render('index.tt');

    } else {
        my %stash;
        $stash{moves_authorize_uri} = client($c)->authorize(
            redirect_uri => redirect_uri($c),
            scope => 'activity',
        );

        return $c->render('signin.tt', \%stash);
    }
}; #}}}

get '/moves/logout' => sub { my $c = shift; #{{{
    $c->session->set(access_token => undef);
    $c->redirect('/');
}; #}}}

get $MOVES_CALLBACK_PATH => sub { my $c = shift; #{{{
    $c->session->set(access_token => access_token($c)->session_freeze);
    $c->redirect('/');
}; #}}}

get '/moves/profile' => sub { my $c = shift; #{{{
    my $res = access_token($c)->get('/api/v1/user/profile');
    my %stash;
    $stash{data} = decode_json $res->content;

    return $c->render('profile.tt', \%stash);
}; #}}}

get '/moves/recent' => sub { my $c = shift; #{{{
    my $from = UnixDate '6 days ago' => '%Y%m%d';
    my $to = UnixDate today => '%Y%m%d';
    my $res = access_token($c)
        ->get("/api/v1/user/summary/daily?from=$from&to=$to");
    my %stash;
    $stash{data} = decode_json $res->content;
    $stash{steps} = [map {
        my $summary = $_->{summary};
        is_array_ref($summary) ?
            (grep { $_->{activity} eq 'wlk' } @$summary)[0]->{steps} : 0;
    } @{$stash{data}}];

    infof \%stash;

    return $c->render('recent.tt', \%stash);
}; #}}}

# load plugins
__PACKAGE__->load_plugin('Web::CSRFDefender');
__PACKAGE__->load_plugin('DBI');
# __PACKAGE__->load_plugin('Web::FillInFormLite');
# __PACKAGE__->load_plugin('Web::JSON');

__PACKAGE__->enable_session(
    store => Plack::Session::Store::DBI->new(
        get_dbh => \&get_dbh,
    ),
);
__PACKAGE__->enable_middleware('Log::Minimal',
    autodump => 1,
);

__PACKAGE__->add_trigger(BEFORE_DISPATCH => sub { my $c = shift;
    $c->redirect('/') if $c->req->path_info =~ m!^/moves!
        && ! defined $c->session->get('access_token');
});

__PACKAGE__->to_app(handle_static => 1);

# helpers
sub client { my $c = shift; #{{{
    my %config = %{$c->config->{site}};
    $config{authorize_path} = $config{authorize_path_for_pc}
        unless $c->req->header('User-Agent') =~ /iPhone/;

    return Net::OAuth2::Profile::WebServer->new(%config);
} #}}}

sub redirect_uri { my $c = shift; #{{{
    my $uri = $c->req->uri;
    $uri->path($MOVES_CALLBACK_PATH);
    $uri->query_form(+{});

    return $uri;
} #}}}

sub access_token { my $c = shift; #{{{
    my $access_token = $c->session->get('access_token');
    if (defined $access_token) {
        return Net::OAuth2::AccessToken->session_thaw($access_token,
            profile => client($c),
        );
    } else {
        return client($c)->get_access_token(
            $c->req->param('code'), redirect_uri => redirect_uri($c));
    }
} #}}}
