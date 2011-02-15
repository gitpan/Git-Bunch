package Git::Bunch;
BEGIN {
  $Git::Bunch::VERSION = '0.01';
}
# ABSTRACT: Manage gitbunch directory (directory which contain git repos)

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Cwd ();
use File::chdir;
use File::Path qw(make_path);
use String::ShellQuote;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(check_bunch sync_bunch backup_bunch);

our %SUBS;

$SUBS{check_bunch} = {
    summary       =>
        'Check status of git repositories inside gitbunch directory',
    description   => <<'_',

Will perform a 'git status' for each git repositories inside the bunch and
report which repositories are 'unclean' (e.g. needs commit, has untracked files,
etc).

_
    required_args => [qw/source/],
    args          => {
        source           => ['str*'   => {
            summary      => 'Directory to check',
            arg_pos      => 0,
        }],
    },
    cmdline_suppress_output => 1,
};
sub check_bunch {
    my %args = @_;
    my $source = $args{source} or return [400, "Please specify source"];
    $source =~ s!/+$!!;
    (-d $source) or return [404, "Source doesn't exist"];

    $log->info("Checking bunch $source ...");

    my %res;
    local $CWD = $source;
    for my $repo (grep {-d} <*>) {
        $CWD = $repo;
        $log->debug("Checking repo $repo ...");

        unless (-d ".git") {
            $log->warn("$repo is not a git repo, ".
                           "please remove it or rename to .$repo");
            $res{$repo} = [400, "Not a git repository"];
        };

        my $output = `LANG=C git status 2>&1`;
        my $exit = $? & 255;
        if ($exit == 0 && $output =~ /nothing to commit/) {
            $log->info("$repo is clean");
        } elsif ($exit == 0 &&
                     $output =~ /Changes to be committed|Changed but/) {
            $log->warn("$repo needs commit");
            $res{$repo} = [500, "Needs commit"];
        } elsif ($exit == 0 && $output =~ /Untracked files/) {
            $log->warn("$repo has untracked files");
            $res{$repo} = [500, "Has untracked files"];
        } elsif ($exit == 128 && $output =~ /Not a git repository/) {
            $log->warn("$repo is not a git repo (2)");
            $res{$repo} = [500, "Not a git repo (2)"];
        } else {
            $log->error("Can't figure out result of 'git status' ".
                            "for repo $repo: exit=$exit, output=$output");
            $res{$repo} = [500, "Unknown (exit=$exit, output=$output)"];
        }
        $CWD = "..";
    }
    [200, "OK", \%res];
}

sub _mysystem {
    $log->trace("system(): ".join(" ", @_));
    system @_;
}

sub _myqx {
    my $cmd = shift;
    $log->trace("qx(): $cmd");
    `$cmd`
}

sub _sync_repo {
    my ($src, $dest, $repo, $opts) = @_;
    my $exit;

    my @src_branches;
    my @dest_branches;
    my %src_heads;  # last revisions for each branch
    my %dest_heads; # last revisions for each branch

    local $CWD = "$src/$repo";
    @src_branches = map {(/^[* ] (.+)/, $1)[-1]} _myqx("LANG=C git branch");
    $exit = $? & 255;
    if ($exit) {
        $log->error("Can't list branches on src repo $src/$repo: $?");
        return [500, "Can't list source branches"];
    }
    $log->debugf("Source branches: %s", \@src_branches);

    for my $branch (@src_branches) {
        my $output = _myqx("LANG=C git log -1 '$branch'");
        $exit = $? & 255;
        if ($exit) {
            $log->error("Can't find out head for branch $branch on src repo ".
                            "$src/$repo: $?");
            return [500, "Can't find out head for source branch $branch"];
        }
        $output =~ /commit (\S+)/ or do {
            $log->error("Can't recognize git log output ".
                            "(searching for commit XXX): $output");
            return [500, "Can't recognize git log output on src: $output"];
        };
        $src_heads{$branch} = $1;
    }
    $log->debugf("Source branch heads: %s", \%src_heads);

    $CWD = "$dest/$repo";
    @dest_branches = map {(/^[* ] (.+)/, $1)[-1]} _myqx("LANG=C git branch");
    if ($exit) {
        $log->error("Can't list branches on dest repo $repo: $?");
        return [500, "Can't list branches on dest: $?"];
    }
    $log->debugf("Dest branches: %s", \@dest_branches);
    for my $branch (@dest_branches) {
        my $output = _myqx("LANG=C git log -1 '$branch'");
        $exit = $? & 255;
        if ($exit) {
            $log->error("Can't find out head for branch $branch on dest repo ".
                            "$dest/$repo: $?");
            return [500, "Can't find out head for dest branch $branch"];
        }
        $output =~ /commit (\S+)/ or do {
            $log->error("Can't recognize git log output ".
                            "(searching for commit XXX): $output");
            return [500, "Can't recognize git log output on src: $output"];
        };
        $dest_heads{$branch} = $1;
    }
    $log->debugf("Dest branch heads: %s", \%dest_heads);

    my $output;
    my $lock_deleted;
  BRANCH:
    for my $branch (@src_branches) {
        # XXX we should allow fetching tags only even if head is the same, but
        # right now tags are not that important
        if ($src_heads{$branch} && $dest_heads{$branch} &&
                $src_heads{$branch} eq $dest_heads{$branch}) {
            $log->debug("Skipping branch $branch because heads are the same");
            next BRANCH;
        }
        if (0 && !$lock_deleted++) {
            $log->debug("Deleting locks first ...");
            unlink "$src/$repo/.git/index.lock";
            unlink "$dest/$repo/.git/index.lock";
        }
        $log->info("Updating branch $branch ...") if @src_branches > 1;
        $output = _myqx(
            join("",
                 "cd '$dest/$repo'; ",
                 ($branch ~~ @dest_branches ? "":"git branch '$branch'; "),
                 "git checkout '$branch' 2>/dev/null; ",
                 "LANG=C git pull '$src/$repo' '$branch' 2>&1"
             ));
        $exit = $? & 255;
        if ($exit == 0 && $output =~ /Already up-to-date/) {
            $log->debug("Branch `$branch is up to date");
            next BRANCH;
        } elsif ($output =~ /^error: (.+)/m) {
            $log->error("Can't successfully git pull branch $branch: $1");
            return [500, "git pull branch $branch failed: $1"];
        } elsif ($exit == 0 &&
                     $output =~ /^Updating |^Merge made by recursive/m) {
            $log->info("  Branch $branch updated") if @src_branches > 1;
            $log->info("  Repo $repo updated"    ) if @src_branches == 1;
        } else {
            $log->error("Can't recognize 'git pull' output for ".
                            "branch $branch: exit=$exit, output=$output");
            return [500, "Can't recognize git pull output: $output"];
        }
        $log->debug("Result of 'git pull' for branch $branch: ".
                        "exit=$exit, output=$output");

        $output = _myqx("cd '$dest/$repo'; ".
                            "LANG=C git fetch --tags '$src/$repo' 2>&1");
        $exit = $? & 255;
        if ($exit != 0) {
            $log->debug("Can't successfully fetch --tags: ".
                            "$output (exit=$exit)");
            return [500, "git fetch --tags failed: $1"];
        }
    }

    if ($opts->{delete_branch}) {
        for my $branch (@dest_branches) {
            next if $branch ~~ @src_branches;
            next if $branch eq 'master'; # can't delete master branch
            $log->info("Deleting branch $branch because it no longer exists ".
                           "in src ...");
            _mysystem("cd '$dest/$repo' && git checkout master 2>/dev/null && ".
                          "git branch -D '$branch' 2>/dev/null");
            if (($? & 255) != 0) {
                $log->error("Can't successfully delete branch $branch: $?");
            }
        }
    }

    [200, "OK"];
}

$SUBS{sync_bunch} = {
    summary       =>
        'Synchronize bunch to another bunch',
    description   => <<'_',

For each git repository in the bunch, will perform a 'git pull' from the
destination for each branch. If repository in destination doesn't exist, it will
be rsync-ed first from source. When 'git pull' fails, will exit to let you fix
the problem manually.

For all other non-git repos, will simply synchronize by one-way rsync.

_
    required_args => [qw/source target/],
    args          => {
        source           => ['str*'   => {
            summary      => 'Source bunch',
            arg_pos      => 0,
        }],
        target           => ['str*'   => {
            summary      => 'Destination bunch',
            arg_pos      => 1,
        }],
        repos            => ['array'   => {
            of           => 'str*',
            summary      => 'Specific git repos to sync, if not specified '.
                'all repos in the bunch will be processed',
        }],
        delete_branch    => ['bool'   => {
            summary      => 'Whether to delete branches in dest repos '.
                'not existing in source repos',
            default      => 0,
        }],
    },
    cmdline_suppress_output => 1,
};
sub sync_bunch {
    my %args = @_;

    # XXX schema
    my $source        = $args{source} or return [400, "Please specify source"];
    $source           =~ s!/+$!!;
    (-d $source) or return [404, "Source doesn't exist"];
    $source           = Cwd::abs_path($source);
    my $target        = $args{target} or return [400, "Please specify target"];
    $target           =~ s!/+$!!;
    $target           = Cwd::abs_path($target);
    my $wanted_repos  = $args{repos};
    return [400, "repos must be an array"]
        if defined($wanted_repos) && ref($wanted_repos) ne 'ARRAY';
    my $delete_branch = $args{delete_branch} // 0;

    my $cmd;

    local $CWD = $source;
    my @entries;
    opendir my($d), "."; @entries = readdir($d);

    unless (-d $target) {
        $log->debugf("Creating target directory %s ...", $target);
        make_path($target)
            or return [500, "Can't create target directory $target: $!"];
    }

    $CWD = $target;
    my %res;
  ENTRY:
    for my $e (@entries) {
        next if $e eq '.' || $e eq '..';
        my $is_repo = (-d "$source/$e") && (-d "$source/$e/.git");
        if (!$is_repo) {
            $log->info("Sync-ing non-git file/directory $e ...");
            $cmd = "rsync -az --del --force ".shell_quote("$source/$e")." .";
            _mysystem($cmd);
            if ($?) {
                $log->warn("Rsync failed, please check: $!");
            }
            next ENTRY;
        }

        if ($wanted_repos && !($e ~~ @$wanted_repos)) {
            $log->debugf("Repo $e is not in wanted repos (%s), skipped",
                         $wanted_repos);
            next ENTRY;
        }

        if (!(-e $e)) {
            $log->info("Copying repo $e ...");
            $cmd = "rsync -az ".shell_quote("$source/$e")." .";
            _mysystem($cmd);
            if ($?) {
                $log->warn("Rsync failed, please check: $!");
            }
            $log->info("  Repo $e copied");
            next ENTRY;
        } else {
            $log->info("Sync-ing repo $e ...");
            my $res = _sync_repo(
                $source, $target, $e,
                {delete_branch => $delete_branch},
            );
            $res{$e} = $res if $res->[0] != 200;
        }
    }

    [200, "OK", {failed_syncs=>\%res}];
}

$SUBS{backup_bunch} = {
    summary       =>
        'Backup bunch directory to another directory using rsync',
    description   => <<'_',

Simply uses rsync to copy bunch directory to another, except that for all git
projects, only .git/ will be rsync-ed. This utilizes the fact that .git/
contains the whole project's data, the working copy can be checked out from
.git/.

Will run check_bunch first and require all repos to be clean before running the
backup, unless 'check' is turned off.

Note: Saving only .git/ subdirectory saves disk space, but will not save
uncommited changes, untracked files, or .gitignore'd files. Make sure you have
committed everything to git before doing backup. Also note that if you need to
restore files, they will be checked out from the repository, and the original
ctime/mtime information is not preserved. backup_bunch() does store this
information for you by saving the output of 'ls -laR' command, but have *not*
implemented routine to restore this data into restored files.

_
    required_args => [qw/source target/],
    args          => {
        source           => ['str*'   => {
            summary      => 'Directory to backup',
            arg_pos      => 0,
        }],
        target           => ['str*'   => {
            summary      => 'Backup destination',
            arg_pos      => 1,
        }],
        check            => ['bool'   => {
            summary      =>
                'Whether to check bunch first before doing backup',
            default      => 1,
        }],
        backup           => ['bool'   => {
            summary      => 'Whether to do actual backup/rsync',
            description  => <<'_',

You can set backup=0 and index=1 to only run indexing, for example.

_
            default      => 1,
        }],
        index            => ['bool'   => {
            summary      => 'Whether to do "ls -laR" after backup',
            default      => 1,
        }],
        extra_rsync_opts => [array    => {
            of           => 'str*',
            summary      => 'Pass extra options to rsync command',
            description  => <<'_',

Extra options to pass to rsync command. Note that the options will be shell
quoted, , so you should pass it unquoted, e.g. ['--exclude', '/Program Files'].

_
        }],
    },

    cmdline_examples => [
        {
            cmd         => '/home/steven/repos /backup/steven/repos --nocheck',
            description => <<'_',

Backup /home/steven/repos to /backup/steven/repos. All git projects inside
/home/steven/repos will be backed up by only copying its .git/, all non-git
directories will be backed up in its entirety. Do not run check_bunch() first.

_
        },
    ],
};
sub backup_bunch {
    my %args = @_;

    # XXX schema
    my $source    = $args{source} or return [400, "Please specify source"];
    $source =~ s!/+$!!;
    (-d $source) or return [404, "Source doesn't exist"];
    my $target    = $args{target} or return [400, "Please specify target"];
    $target       =~ s!/+$!!;
    my $check     = $args{check}  // 1;
    my $backup    = $args{backup} // 1;
    my $index     = $args{index}  // 1;

    my $res;
    if ($check) {
        $res = check_bunch(source => $source);
        return $res unless $res->[0];
        return [500, "Some repos are not clean, please fix first"]
            if keys %{$res->[2]};
    }

    unless (-d $target) {
        $log->debugf("Creating target directory %s ...", $target);
        make_path($target)
            or return [500, "Can't create target directory $target: $!"];
    }

    if ($backup) {
        $log->info("Backing up bunch $source ===> $target ...");
        my $cmd = join(
            "",
            "rsync -az ",
            ($log->is_trace() ? "-Pv" : ($log->is_debug() ? "-v" : "")), " ",
            "--include / ",
            # dot-dirs are included recursively
            "--include '/.??*' --include '/.??*/**' ",
            # nondot-dirs are assumed git as repos, only .git/ copied from each
            "--include '/*' --include '/*/.git' --include '/*/.git/**' ",
            "--exclude '*' ",
            "--del --force --delete-excluded ",
            shell_quote($source), "/ ",
            shell_quote($target), "/"
        );
        _mysystem($cmd);
        return [500, "Backup did not succeed, please check: $!"] if $?;
    }

    if ($index) {
        $log->info("Indexing bunch $source ...");
        local $CWD = $source;
        my $cmd = "( ls -laR | gzip -c > .ls-laR.gz ) && ".
            "cp .ls-laR.gz ".shell_quote($target);
        _mysystem($cmd);
        return [500, "Indexing did not succeed, please check: $!"] if $?;
    }

    [200, "OK"];
}

1;


=pod

=head1 NAME

Git::Bunch - Manage gitbunch directory (directory which contain git repos)

=head1 VERSION

version 0.01

=head1 SYNOPSIS

To check the status of bunch (will do a 'git status' for each git repo inside
the bunch and report which repos are 'unclean', e.g. needs commit, has untracked
files, etc):

 % gitbunch check ~/repos

To synchronize bunch to another (will do a 'git pull' for each git repo, and do
an rsync for everything else):

 % gitbunch sync ~/repos /mnt/laptop/repos

To backup bunch (will only rsync .git/ for each git repo to destination, and
rsync everything else in full):

 % gitbunch backup ~/repos /media/flashdisk

=head1 DESCRIPTION

A B<gitbunch> or B<bunch> directory is just a term I coined to refer to a
directory which contains, well, a bunch of git repositories. It can also contain
other stuffs like files and non-git repositories (but they must be dot-dirs).
Example:

 repos/            -> a gitbunch dir
   proj1/          -> a git repo
   proj2/          -> ditto
   perl-Git-Bunch/ -> ditto
   ...
   .foo/           -> a non-git dir
   README.txt      -> file

A little bit of history: after B<git> got popular, in 2008 I started using it
for software projects, replacing Subversion and Bazaar. Soon, I moved everything
to git: notes & writings, Emacs .org agenda files, configuration, even temporary
downloads/browser-saved HTML files. Currently, except large media files, all my
personal data resides in git repositories. I put them all in ~/repos (and add
symlinks to various places for convenience). This setup makes it easy to sync to
laptops, backup to disk, etc. Git::Bunch is the library/script I wrote to do
this.

See also L<File::RsyBak>, which I wrote to backup everything else.

=head1 FUNCTIONS

None of the functions are exported by default, but they are exportable.

=head2 backup_bunch(%args) -> RESP


Backup bunch directory to another directory using rsync.

Simply uses rsync to copy bunch directory to another, except that for all git
projects, only .git/ will be rsync-ed. This utilizes the fact that .git/
contains the whole project's data, the working copy can be checked out from
.git/.

Will run check_bunch first and require all repos to be clean before running the
backup, unless 'check' is turned off.

Note: Saving only .git/ subdirectory saves disk space, but will not save
uncommited changes, untracked files, or .gitignore'd files. Make sure you have
committed everything to git before doing backup. Also note that if you need to
restore files, they will be checked out from the repository, and the original
ctime/mtime information is not preserved. backup_bunch() does store this
information for you by saving the output of 'ls -laR' command, but have *not*
implemented routine to restore this data into restored files.

Arguments (C<*> denotes required arguments):

=over 4

=item * B<source>* => I<str>

Directory to backup.

=item * B<target>* => I<str>

Backup destination.

=item * B<backup> => I<bool> (default C<1>)

Whether to do actual backup/rsync.

You can set backup=0 and index=1 to only run indexing, for example.

=item * B<check> => I<bool> (default C<1>)

Whether to check bunch first before doing backup.

=item * B<extra_rsync_opts> => I<array>

Pass extra options to rsync command.

Extra options to pass to rsync command. Note that the options will be shell
quoted, , so you should pass it unquoted, e.g. ['--exclude', '/Program Files'].

=item * B<index> => I<bool> (default C<1>)

Whether to do "ls -laR" after backup.

=back

=head2 check_bunch(%args) -> RESP


Check status of git repositories inside gitbunch directory.

Will perform a 'git status' for each git repositories inside the bunch and
report which repositories are 'unclean' (e.g. needs commit, has untracked files,
etc).

Arguments (C<*> denotes required arguments):

=over 4

=item * B<source>* => I<str>

Directory to check.

=back

=head2 sync_bunch(%args) -> RESP


Synchronize bunch to another bunch.

For each git repository in the bunch, will perform a 'git pull' from the
destination for each branch. If repository in destination doesn't exist, it will
be rsync-ed first from source. When 'git pull' fails, will exit to let you fix
the problem manually.

For all other non-git repos, will simply synchronize by one-way rsync.

Arguments (C<*> denotes required arguments):

=over 4

=item * B<source>* => I<str>

Source bunch.

=item * B<target>* => I<str>

Destination bunch.

=item * B<delete_branch> => I<bool> (default C<0>)

Whether to delete branches in dest repos not existing in source repos.

=item * B<repos> => I<array>

Specific git repos to sync, if not specified all repos in the bunch will be processed.

=back

=head1 FAQ

=head1 TODO

=head1 SEE ALSO

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

