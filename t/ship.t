use Test::More;
use App::git::ship;

my $app = App::git::ship->new;

{
  ok !$app->can('some_attr'), 'some_attr() does not exist';
  $app->attr(some_attr => sub { 123 });
  ok $app->can('some_attr'), 'some_attr() injected';
  ok !exists $app->{some_attr}, 'some_attr does not exist';
  is $app->some_attr, 123, 'some_attr() 123';
  ok exists $app->{some_attr}, 'some_attr exists';
}

SKIP: {
  skip '.git is not here', 1 unless -d '.git';

  my $author = $app->author('%an, <%ae>');
  like $author, qr{^[^,]+, <[^\@]+\@[^\>]+>$}, 'got author and email';

  $author =~ s!,\s<.*!!;
  is $app->author, $author, 'got author';
}

{
  eval { $app->abort("foo") };
  like $@, qr{^git-ship: foo}, 'abort foo';

  eval { $app->abort("foo %s", 123) };
  like $@, qr{^git-ship: foo 123}, 'abort foo 123';
}

{
  eval { $app->system(perl => '-e', '$!=42;die') };
  like $@, qr{^git-ship: 'perl -e \$!=42;die' failed: 42}, 'system() failed';
}

{
  eval { $app->build };
  like $@, qr{^git-ship: build}, 'build() cannot do anything';

  eval { $app->test };
  like $@, qr{^git-ship: test}, 'test() cannot do anything';
}

done_testing;
