use Test::More;
use App::git::ship::perl;

my $app = App::git::ship::perl->new;

SKIP: {
  skip '.git is not here', 1 unless -d '.git';

  my $author = $app->_author('%an, <%ae>');
  like $author, qr{^[^,]+, <[^\@]+\@[^\>]+>$}, 'got author and email';

  $author =~ s!,\s<.*!!;
  is $app->_author, $author, 'got author';
}

done_testing;
