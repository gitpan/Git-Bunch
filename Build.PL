
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  'build_requires' => {
    'Module::Build' => '0.3601'
  },
  'configure_requires' => {
    'Module::Build' => '0.3601'
  },
  'dist_abstract' => 'Manage gitbunch directory (directory which contain git repos)',
  'dist_author' => [
    'Steven Haryanto <stevenharyanto@gmail.com>'
  ],
  'dist_name' => 'Git-Bunch',
  'dist_version' => '0.09',
  'license' => 'perl',
  'module_name' => 'Git::Bunch',
  'recommends' => {},
  'recursive_test_files' => 1,
  'requires' => {
    'File::Slurp::Shortcuts' => '0',
    'File::Which' => '0',
    'File::chdir' => '0',
    'Log::Any' => '0',
    'Log::Any::App' => '0',
    'String::ShellQuote' => '0',
    'Sub::Spec::CmdLine' => '0.25',
    'autodie' => '0',
    'perl' => '5.010000'
  },
  'script_files' => [
    'bin/gitbunch'
  ]
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
