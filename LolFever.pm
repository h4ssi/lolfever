# LoLfever - random meta ftw
# Copyright (C) 2013  Florian Hassanen
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package LolFever;

use Modern::Perl;

use Mojolicious::Lite;
use Method::Signatures::Simple;

use URI;
use Web::Scraper;
use Data::Dumper;

use Digest;

my $config = plugin 'Config';
my $base = $config->{'base'} // '';

app->secret('asdfp421c4 1r_');

func parse_role($role) {
    if( $role =~ /mid/xmsi ) {
        return 'mid';     
    } elsif ( $role =~ /top/xmsi ) {
        return 'top';
    } elsif ( $role =~ /supp/xmsi ) {
        return 'support';
    } elsif ( $role =~ /ad|bot/xmsi ) {
        return 'adcarry';
    } elsif ( $role =~ /jungl/xmsi ) {
        return 'jungle';
    } else {
        return;
    }
}

func write_db( $file, $data ) {
    open(my $f, '>', $file);

    while( my ($key, $values) = each %$data ) {
        for my $value ( keys %$values ) {
            say {$f} "$key:$value" if $data->{$key}->{$value};
        }
    }

    close $f;
}

func read_db( $file ) {
    open(my $f, '<', $file);

    my %data;

    while(my $l = <$f>) {
        chomp $l;

        my ($key,$val) = split /:/xms, $l, 2;

        $data{$key} = {} unless defined $data{$key};

        $data{$key}->{$val} = 1;
    }

    close $f;

    return \%data;
}


get "$base/updatedb" => method {
    my $champion_list_scraper = scraper {
        process '.champion-list tr', 'champions[]' => scraper {
            process '.champion-list-icon > a', href => '@href';
            process '//td[last()-1]', role => '@data-sortval';
        };
    };

    my $champion_guide_scraper = scraper {
        process "#guides-champion-list > .big-champion-icon", 'champions[]' => { name => '@data-name', m0 => '@data-meta', map { ( "m$_" => "\@data-meta$_" ) } (1..5) };
    };

    my %db;
    my @errors;

    my $champions = $champion_list_scraper->scrape( URI->new('http://www.lolking.net/champions') );

    for my $c ( @{ $champions->{'champions'} } ) {
        if( defined $c->{'href'} ) {
            unless( $c->{'href'} =~ / ( [^\/]*? ) \z/xms ) {
                push @errors, 'Could not parse champion name from: '.($c->{'href'});
            } else {
                my $name = $1;
                $name = 'wukong' if $name eq 'monkeyking';

                my %roles;
                $db{$name} = \%roles;

                unless( defined $c->{'role'} ) {
                    push @errors, "No role found for champion $name";
                } else {
                    my $r = parse_role($c->{'role'});
                    
                    unless( defined $r ) {
                        push @errors, "Do not know what role this is: ".($c->{'role'});
                    } else {
                        $roles{$r} = 1;
                    }
                }
            }
        }
        
    }

    my $champion_guides = $champion_guide_scraper->scrape( URI->new('http://www.lolking.net/guides') );

    for my $c ( @{ $champion_guides->{'champions'} } ) {
        my @roles = grep { defined && /\w/xms } @$c{ qw<m0 m1 m2 m3 m4 m5> };

        (my $name = $c->{'name'}) =~ s/[^a-zA-Z]//xmsg;

        unless( defined $db{$name} ) {
            push @errors, "No such champion: $name/".($c->{'name'});
        } else {
            for my $role (@roles) {
                my $r = parse_role($role);

                unless( defined $r ) {
                    push @errors, "Do not know what role this is again: $role";
                } else {
                    $db{$name}->{$r} = 1;
                }
            }
        }
    }

    write_db('champions.db', \%db);

    $self->render( text => Dumper({ errors => \@errors, db => {%db} }) );
};

get "$base/user/:name" => method {
    my $name = $self->param('name');
    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name" );
    }

    my $data = read_db("$name.db");
    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    $self->render($self->param('edit') ? 'user_edit' : 'user', user => $name, names => \@names, owns => $data->{'owns'}, can => $data->{'can'}, pw => !!$data->{'pwhash'});
};

post "$base/user/:name" => method {
    my $name = $self->param('name');

    unless( defined $name && $name =~ /\w/xms && -f "$name.db" ) {
        return $self->render( text => "No such user: $name" );
    }

    my $data = read_db("$name.db");
    
    unless( $data->{'pw'} || $data->{'pwhash'} ) {
        return $self->render( text => "User deactivated: $name" );
    }

    my $champions = read_db('champions.db');
    my @names = sort ( keys %$champions );

    my $d = Digest->new('SHA-512')->add( app->secret );
    
    my $auth;

    if( $data->{'pwhash'} ) {
        ($auth) = keys %{ $data->{'pwhash'} };
    } else {
        my ($plain) = keys %{ $data->{'pw'} };
        $auth = $d->clone->add( $plain )->b64digest;
    }

    my $given = $d->clone->add( $self->param('current_pw') )->b64digest;
  
    say Dumper( { auth => $auth, given => $given });

    unless( $auth eq $given ) {
        return $self->render( text => "invalid pw" );
    }

    if( $self->param('new_pw_1') ) {
        unless( $self->param('new_pw_1') eq $self->param('new_pw_2') ) {
            return $self->redner( text => "new pws did not match" );
        } else {
            $data->{'pwhash'} = {} unless defined $data->{'pwhash'};
            $data->{'pwhash'}->{ $d->clone->add( $self->param('new_pw_1') )->b64digest } = 1;
        }
    }

    $data->{'can'} = {} unless defined $data->{'can'};
    for my $role (qw<top mid adcarry support jungle>) {
        $data->{'can'}->{$role} = !!$self->param("can:$role");
    }

    $data->{'owns'} = {} unless defined $data->{'owns'};
    for my $champ (@names) {
        $data->{'owns'}->{$champ} = !! $self->param("owns:$champ");
    }

    write_db("$name.db", $data);

    return $self->redirect_to;
};

app->start;

__DATA__

@@ user.html.ep
<h1><%= $user %></h1>
<h2>Possible roles</h2>
<ul>
% for my $c (qw<top mid adcarry support jungle>) {
%   if( $can->{$c} ) {
        <li><%= $c %></li>
%   }
% }
</ul>
<h2>Owned champions</h2>
<ul>
% for my $n (@$names) {
%   if( $owns->{$n} ) {
        <li><%= $n %></li>
%   }
% }
</ul>
%= link_to Edit => url_for->query(edit => 1)
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!<small></div>

@@ user_edit.html.ep
<h1><%= $user %></h1>
%= form_for url_for() => (method => 'POST') => begin
<h2>Possible roles</h2>
% for my $c (qw<top mid adcarry support jungle>) {
    <div>
%= input_tag "can:$c", type => 'checkbox', value => 1, $can->{$c} ? ( checked => 'checked' ) : ()
    <%= $c %>
    </div>
% }
<h2>Owned champions</h2>
% for my $n (@$names) {
    <div>
%= input_tag "owns:$n", type => 'checkbox', value => 1, $owns->{$n} ? ( checked => 'checked' ) : ()
    <%= $n %>
    </div>
% }
<h2>Authentication</h2>
Current password <strong>(required)</strong>: 
%= input_tag 'current_pw', type => 'password'
<br />
New password 
% if( !$pw ) {
    <strong>(Password change required!)</strong>:
% } else {
    (Leave empty if you do not want to change your password):
% }
%= input_tag 'new_pw_1', type => 'password'
<br />
Retype new password:
%= input_tag 'new_pw_2', type => 'password'
<br />
%= submit_button 'Save'
%
%end
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!<small></div>