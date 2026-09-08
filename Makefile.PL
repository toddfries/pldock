use ExtUtils::MakeMaker;
WriteMakefile
(
  'NAME' => 'Pldock',
  'VERSION_FROM' => 'lib/Pldock.pm',
  'PREREQ_PM' => {},
  'INSTALLDIRS' => 'site',
  'EXE_FILES' => [ 'pldock' ],
  'PL_FILES' => {},
  'MAN1PODS' => {
                   'pldock.1' => '$(INST_MAN1DIR)/pldock.1',
                   'pldock.conf.1' => '$(INST_MAN1DIR)/pldock.conf.1',
                 },
)
;
