#!/usr/local/ensembl/bin/perl

use strict;
use Getopt::Long;

use Bio::EnsEMBL::Utils::Exception qw(stack_trace);
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Analysis::Config::Databases;
use Bio::EnsEMBL::Analysis::Config::Pseudogene;
use Bio::EnsEMBL::Pipeline::DBSQL::FlagAdaptor;
use Bio::EnsEMBL::Pipeline::Utils::InputIDFactory;
use Bio::SeqIO;


my $usage = "prepare_SplicedElsewhere.pl -logic_name <dummy analysis which will run spliced elsewhere>
Loads input ids into pseudo_db and gets output files from pseudogene and makes them into a blast db";
my @dbID;
my $count =0;
my $num=0;
my $start;
my $logic_name;
my @input_ids;
my @multiexon_files;

&GetOptions('-logic_name:s' => \$logic_name);

die $usage unless($logic_name);

my $dna_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
  (
   '-host'   => $GB_DBHOST,
   '-user'   => $GB_DBUSER,
   '-dbname' => $GB_DBNAME,
   '-pass'   => $GB_DBPASS,
   '-port'   => $GB_DBPORT,
  );

#genes come from final genebuild database
my $genes_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
  (
   '-host'   => $GB_FINALDBHOST,
   '-user'   => $GB_FINALDBUSER,
   '-dbname' => $GB_FINALDBNAME,
   '-pass'   => $GB_FINALDBPASS,
   '-port'   => $GB_FINALDBPORT,
   '-dnadb'  => $dna_db,
  );

my $final_db = new Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor
  (
   '-host'   => $PSEUDO_DBHOST,
   '-user'   => $PSEUDO_DBUSER,
   '-dbname' => $PSEUDO_DBNAME,
   '-pass'   => $PSEUDO_DBPASS,
   '-port'   => $PSEUDO_DBPORT,
  );

my $ga = $genes_db->get_GeneAdaptor;

if ($SINGLE_EXON) {
  print "Making input ids for single exon genes\n";
  my $fa = Bio::EnsEMBL::Pipeline::DBSQL::FlagAdaptor->new($final_db);
  my $aa = $final_db->get_AnalysisAdaptor;
  my $analysis = $aa->fetch_by_logic_name($SINGLE_EXON);
  die("analysis object not found $SINGLE_EXON\n") unless ($analysis);
  my @ids = @{$fa->fetch_by_analysis($analysis)};
  @ids = sort {$a->dbID <=> $b->dbID} @ids;
  foreach my $id (@ids){
    if ($count==0){
       $start = $id->dbID; 
     }
    $count++;
    if ($count == $PS_CHUNK){
      $num++;
      push @input_ids,"$start:".$id->dbID;
      $count=0;
    }
  }
  if ($count >0){
   push @input_ids,"$start:".$ids[$#ids]->dbID;
  }

  my $inputIDFactory = new Bio::EnsEMBL::Pipeline::Utils::InputIDFactory
    (
     -db => $final_db,
     -top_level => 'top_level',
     -slice     => 'ignore this warning its just stupid',,
     -logic_name => $logic_name,
    );
  $inputIDFactory->input_ids(\@input_ids);
  $inputIDFactory->store_input_ids;

 print STDERR "Pooling multiexon genes into single blastDB .\n";

  my $db_output = Bio::SeqIO->new(
				  -file => ">$PS_MULTI_EXON_DIR"."all_multi_exon_genes.fasta",
				  -format => 'fasta'
				 );

  my @multiexon_files = split(/\n/,`ls $PS_MULTI_EXON_DIR/multi_exon_seq*.fasta`);
  foreach my $file (@multiexon_files) {
    my $bioseq = Bio::SeqIO->new(
				 -file   => $file,
				 -format => 'fasta'
				);
    while (my $seq = $bioseq->next_seq) {
      $db_output->write_seq($seq);
    }
 #   system ("rm $file");
  }
  system ("xdformat -p $PS_MULTI_EXON_DIR/all_multi_exon_genes.fasta");
}

print "Finished\n";

exit 0;
