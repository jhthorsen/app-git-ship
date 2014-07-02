package App::git::ship::Manual;

=head1 NAME

git-ship - A git command for shipping your project

=head1 SYNOPSIS

  # Set up the config file
  $ git ship init

  # The command below will ship your project
  $ git ship

=head1 DESCRIPTION

This script can ship your Perl project with ease, but can also be extended
to support any other language.

The program runs through these steps by default:

=head2 Config

The first step is to read the L<config file|App::git::ship/config>. If the
config cannot be read, the app will set up a L<default config|App::git::ship/init>
file with as much information as possible.

=head2 Detect

The next step is to L<detect|App::git::ship/detect> what kind of project type
this is and delegate the job to a given handler.

=head2 Ship

The last step is to run L<ship|App::git::ship/ship> the project off to an
external repository. This part can be customized by any module.

The default is simply to tag and push the repository to github.

=head1 SEE ALSO

L<App::git::ship>.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
