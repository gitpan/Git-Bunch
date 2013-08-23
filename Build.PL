
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Module::Build" => "0.3601"
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Manage gitbunch directory (directory which contain git repos)",
  "dist_author" => [
    "Steven Haryanto <stevenharyanto\@gmail.com>"
  ],
  "dist_name" => "Git-Bunch",
  "dist_version" => "0.30",
  "license" => "perl",
  "module_name" => "Git::Bunch",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "Builtin::Logged" => 0,
    "File::chdir" => 0,
    "Log::Any" => 0,
    "Perinci::CmdLine" => "0.79",
    "Rinci" => "v1.1.14",
    "String::ShellQuote" => 0,
    "perl" => "5.010001"
  },
  "script_files" => [
    "bin/gitbunch"
  ],
  "test_requires" => {
    "Capture::Tiny" => 0,
    "File::Slurp::Shortcuts" => 0,
    "File::Which" => 0,
    "Probe::Perl" => 0,
    "Test::More" => "0.96",
    "Test::Script" => "1.05",
    "blib" => 0
  }
);


unless ( eval { Module::Build->VERSION(0.4004) } ) {
  my $tr = delete $module_build_args{test_requires};
  my $br = $module_build_args{build_requires};
  for my $mod ( keys %$tr ) {
    if ( exists $br->{$mod} ) {
      $br->{$mod} = $tr->{$mod} if $tr->{$mod} > $br->{$mod};
    }
    else {
      $br->{$mod} = $tr->{$mod};
    }
  }
}

my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
