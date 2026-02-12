use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'GitHub::Copilot',
    VERSION_FROM     => 'lib/GitHub/Copilot/Client.pm',
    ABSTRACT         => 'Perl SDK for the GitHub Copilot CLI',
    AUTHOR           => 'Microsoft Corporation',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '5.020',
    PREREQ_PM        => {
        'Moo'           => '2.005',
        'JSON::PP'      => '4.00',
        'IPC::Open3'    => 0,
        'threads'       => 0,
        'Thread::Queue' => 0,
        'Carp'          => 0,
        'Scalar::Util'  => 0,
        'Time::HiRes'   => 0,
        'File::Which'   => 0,
        'UUID::Tiny'    => 0,
    },
    TEST_REQUIRES => {
        'Test::More'      => '0.96',
        'Test::Exception' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/github/copilot-sdk.git',
                web  => 'https://github.com/github/copilot-sdk',
            },
            bugtracker => {
                web => 'https://github.com/github/copilot-sdk/issues',
            },
        },
    },
);
