use Test::More;
use App::git::ship::perl;

plan skip_all => 'No Changes file' unless -r 'Changes';

my $app = App::git::ship::perl->new;

like $app->_changes_to_commit_message, qr{Released version [\d\._]+\n\n\s+}, '_changes_to_commit_message()';

done_testing;
