
#
# Cared for by EnsEMBL  <ensembl-dev@ebi.ac.uk>
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Pipeline::RunnableDB::FilterESTs_and_E2G

=head1 SYNOPSIS

    my $obj = Bio::EnsEMBL::Pipeline::RunnableDB::FilterESTs_and_E2G->new(
									  -db          => $db,
									  -input_id    => $id,
									  -seq_index   => $index
									 );
    $obj->fetch_input
    $obj->run

    mc @genes = $obj->output;


=head1 DESCRIPTION

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

# Let the code begin...

package Bio::EnsEMBL::Pipeline::RunnableDB::FilterESTs_and_E2G;

use vars qw(@ISA);
use strict;
use POSIX;

# Object preamble
use Bio::EnsEMBL::Pipeline::RunnableDB;
use Bio::EnsEMBL::Pipeline::Runnable::MiniEst2Genome;
use Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter;
use Bio::EnsEMBL::Pipeline::DBSQL::ESTFeatureAdaptor;
#use Bio::EnsEMBL::Pipeline::SeqFetcher::BioIndex;
#use Bio::EnsEMBL::Pipeline::SeqFetcher::Getseqs;
#use Bio::EnsEMBL::Pipeline::SeqFetcher::Pfetch;
use Bio::EnsEMBL::Pipeline::SeqFetcher::OBDAIndexSeqFetcher;
use Bio::EnsEMBL::Gene;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Translation;
use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Pipeline::Tools::BPlite;
#use FileHandle;

use Bio::EnsEMBL::Pipeline::ESTConf qw (
					EST_REFDBHOST
					EST_REFDBNAME
					EST_REFDBUSER
					EST_DBNAME
					EST_DBHOST
					EST_DBUSER 
					EST_DBPASS
					EST_SOURCE
					EST_INDEX
					EST_MIN_PERCENT_ID
					EST_MIN_COVERAGE
					EST_INPUTID_REGEX
				       );


@ISA = qw( Bio::EnsEMBL::Pipeline::RunnableDB );


=head2 new
  Args       :  -db:         A Bio::EnsEMBL::DBSQL::DBAdaptor (required),
                             The database which output is written to 
                -input_id:   Contig input id (required), 
                -seqfetcher: A Sequence Fetcher Object (required),
                -analysis:   A Bio::EnsEMBL::Analysis (optional) ;
  Example    : $self->new(-DB          => $db
                          -INPUT_ID    => $id
                          -ANALYSIS    => $analysis);
  Description: creates a 
                Bio::EnsEMBL::Pipeline::RunnableDB::ExonerateESTs
                object
  Returntype : A Bio::EnsEMBL::Pipeline::RunnableDB::ExonerateESTs
                object
  Exceptions : None
  Caller     : General

=cut


sub new {
  my ($class, @args) = @_;
  my $self = $class->SUPER::new(@args);
	   
  # we force it to use BioIndex SeqFetcher
  my $seqfetcher = $self->make_seqfetcher();
  $self->seqfetcher($seqfetcher);
    
  # Pull config info from ESTConf.pl      
  my $refdbname = $EST_REFDBNAME;
  my $refdbuser = $EST_REFDBUSER;
  my $refdbhost = $EST_REFDBHOST;

  #print STDERR "refdb: $refdbname $refdbhost $refdbuser\n";
  my $estdbname = $EST_DBNAME;
  my $estdbuser = $EST_DBUSER;
  my $estdbhost = $EST_DBHOST;
  my $estpass   = $EST_DBPASS;

  #print STDERR "estdb: $estdbname $estdbhost $estdbuser $estpass\n";
	 
  # database with the dna:
  my $refdb = new Bio::EnsEMBL::DBSQL::DBAdaptor(-host   => $refdbhost,		
						 -user   => $refdbuser,
						 -dbname => $refdbname);
	 
  # database where the exonerate est/cdna features are:
  my $estdb = new Bio::EnsEMBL::DBSQL::DBAdaptor(-host   => $estdbhost,		
						 -user   => $estdbuser,
						 -dbname => $estdbname,
						 -pass   => $estpass);
	 
  $self->estdb($estdb);
  $self->estdb->dnadb($refdb);
	 
  # need to have an ordinary adaptor to the est database for gene writes
  $self->db->dnadb($refdb);
	 
  $self->make_analysis unless (defined $self->analysis);
	 
  return $self;
}



=head2 estdb

  Arg [1]    : Bio::EnsEMBL::DBSQL::DBAdaptor $value
  Example    : $self->estdb($obj);
  Description: Gets or sets the value of estdb. ESTs are read from this db.
  Returntype : Bio::EnsEMBL::DBSQL::DBAdaptor
  Exceptions : thrown if $value arg is not a DBAdaptor
  Caller     : general

=cut

sub estdb {
    my( $self, $value ) = @_;
    
    if ($value) 
    {
        $value->isa("Bio::EnsEMBL::DBSQL::DBAdaptor")
            || $self->throw("Input [$value] isn't a Bio::EnsEMBL::DBSQL::DBAdaptor");
        $self->{'_est_db'} = $value;
    }
    return $self->{'_est_db'};
}


=head2 write_output

  Arg [1]    : none 
  Example    : $self->write_output
  Description: Writes genes to db, and also writes out exons as features with an 
               appropriate analysis type
  Returntype : none
  Exceptions : thrown if the db is not available
  Caller     : run_RunnableDB

=cut

sub write_output {
    my($self) = @_;
    
    my $estdb = $self->db;

    if( !defined $estdb ) {
      $self->throw("unable to make write db");
    }
    
    $self->write_genes();
}


=head2 write_genes

  Arg [1]    : none
  Example    : $self->write_genes; 
  Description: Writes genes to db
  Returntype : none
  Exceptions : none
  Caller     : write_output

=cut

sub write_genes {
  my ($self) = @_;
  my $gene_adaptor = $self->db->get_GeneAdaptor;

 GENE: foreach my $gene ($self->output) {	
    eval {
      $gene_adaptor->store($gene);
      print STDERR "Wrote gene " . $gene->dbID . "\n";
    }; 
    if( $@ ) {
      print STDERR "UNABLE TO WRITE GENE\n\n$@\n\nSkipping this gene\n";
    }
    
  }
}


=head2 fetch_input

  Arg [1]    : none
  Example    : $runnable->fetch_input
  Description: Fetches input databa for ExonerateESTs and makes runnable
  Returntype : none
  Exceptions : thrown if $self->input_id is not defined
  Caller     : run_RunnableDB

=cut

sub fetch_input {
  my ($self) = @_;
  
    $self->throw("No input id") unless defined($self->input_id);

  # get Slice of input region
  $self->input_id  =~ /$EST_INPUTID_REGEX/;
  my $chrid = $1;
  my $chrstart  = $2;
  my $chrend    = $3;

  my $slice_adaptor = $self->estdb->get_SliceAdaptor();
  my $slice    = $slice_adaptor->fetch_by_chr_start_end($chrid,$chrstart,$chrend);
  $self->vcontig($slice);

  # find exonerate features amongst all the other features  
  my $allfeatures = $self->estdb->get_DnaAlignFeatureAdaptor->fetch_all_by_Slice($slice);

  my @exonerate_features;
  my %exonerate_ests;
  my $est_source = $EST_SOURCE;

  foreach my $feat(@$allfeatures){
    unless(defined($feat->analysis) && 
	   defined($feat->score) && 
	   defined($feat->analysis->db) && 
	   $feat->analysis->db eq $est_source) {
      $self->warn( "FilterESTs_and_E2G: something went wrong:\n" .
		   "analysis: ".$feat->analysis." analysis_db: " .
		   $feat->analysis->db." =? est_source: ".$est_source."\n");
      next;
    }      
    
    # only take high scoring ests
    if($feat->percent_id >= $EST_MIN_PERCENT_ID){
      if(!defined $exonerate_ests{$feat->hseqname}){
	push (@{$exonerate_ests{$feat->hseqname}}, $feat);
      }
      push (@exonerate_features, $feat);
    }
  }

  # empty out massive arrays
  $allfeatures = undef;

  #print STDERR "exonerate features left with percent_id >= $EST_MIN_PERCENT_ID : " . scalar(@exonerate_features) . "\n";
  #print STDERR "num ests " . scalar(keys %exonerate_ests) . "\n\n";
  
  unless( @exonerate_features ){
    print STDERR "No exonerate features left, exiting...\n";
    exit(0);
  }
  
  # filter features, current depth of coverage 10, and group successful ones by est id
  my %filtered_ests;
  
  # use coverage 10 for now.
  my $filter = Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter->new( '-coverage' => 10,
								     '-minscore' => 500,
								     '-prune'    => 1,
								   );
  my @filteredfeats = $filter->run(@exonerate_features);
  
  # empty out massive arrays
  @exonerate_features = ();

  foreach my $f(@filteredfeats){
    push(@{$filtered_ests{$f->hseqname}}, $f);
  }
  #print STDERR "num filtered features ". scalar( @filteredfeats) . "\n";  

  # empty out massive arrays
  @filteredfeats = ();

  #print STDERR "num filtered ests " . scalar(keys %filtered_ests) . "\n";

  # reinstate blast
  my @blast_features = $self->blast(keys %filtered_ests);
  print STDERR "back from blast with " . scalar(@blast_features) . " features\n";
  
  unless (@blast_features) {
    $self->warn("Odd - no exonerate features, cannot make runnables\n");
    return;
  }

  my %final_ests;
  foreach my $feat(@blast_features) {
    my $id = $feat->hseqname;

    # very annoying white space nonsense
    $id =~ s/\s//;
    $feat->hseqname($id);
    push(@{$final_ests{$id}}, $feat);
  }

  # make one runnable per EST set
  my $rcount = 0;
  my $single = 0;
  my $multi  = 0;
  
  my $efa = new Bio::EnsEMBL::Pipeline::DBSQL::ESTFeatureAdaptor($self->db);
  
  # only fetch this once for the whole set or it's SLOW!
  my $genomic  = $self->vcontig->get_repeatmasked_seq;
  
#  # keep track of those ESTs who make it into a MiniEst2genome
#  my %accepted_ests;
  
 ID:    
  foreach my $id(keys %final_ests) {
    # length coverage check for every EST
    
    my $hitlength;
    my $hitstart;
    my $hitend;
    foreach my $f(@{$final_ests{$id}}){
      if(!defined $hitstart || (defined $hitstart && $f->hstart < $hitstart)){
	$hitstart = $f->hstart;
      }

      if(!defined $hitend || (defined $hitend && $f->hend > $hitend)){
	$hitend = $f->hend;
      }
    }
    
    $hitlength = $hitend - $hitstart + 1;
    my $estlength = $efa->get_est_length($id);
    if(!defined $estlength || $estlength < 1){
      print STDERR "problem getting length for [$id]\n";
      next ID;
    }
    
    my $coverage = ceil(100 * ($hitlength/($estlength)));
    if($coverage < $EST_MIN_COVERAGE){
      print STDERR "rejecting $id for insufficient coverage ( < $EST_MIN_COVERAGE ): $coverage %\n";
      if(scalar(@{$final_ests{$id}}) == 1){
	$single++;
      }
      else{
	$multi++;
      }
      next ID;
    }
  
    # before making a MiniEst2Genome, check that the one we're about to create
    # is not redundant with any one we have created before
#    my $do_comparison_stuff = 0;
#    if ( $do_comparison_stuff == 1 ){
    
#      foreach my $id2 ( keys( %accepted_ests ) ){
	
#	# compare $id with each $id2
#	# if $id is redundant, skip it
#	my @feat1 = sort{ $a->start <=> $b->start } @{$final_ests{$id}};
#	my @feat2 = sort{ $a->start <=> $b->start } @{$accepted_ests{$id2} };
#	#print STDERR "comparing ".$id."(".scalar(@feat1).") with ".$id2." (".scalar(@feat2).")\n";    
	
#	if ( scalar( @feat1 ) == scalar( @feat2 ) ){
#	  print STDERR "$id and $id2 have the same number of features\n";
	  
#	  # first, let's make a straightforward check for exac matches:
#	  my $label = 0;
#	  while ( $label < scalar( @feat1 )                      &&
#		  $feat1[$label]->start == $feat2[$label]->start &&
#		  $feat1[$label]->end   == $feat2[$label]->end   ){	        
#	    print STDERR ($label+1)." == ".($label+1)."\n";
#	    $label++;
#	  }
#	  if ( $label == scalar( @feat1 ) ){
#	    print STDERR "EXACT MATCH between $id and $id2 features, skipping $id\n";
#	  }
#	  # make also a test for overlaps
#	  $label = 0;
#	  while ( $label < scalar( @feat1 ) && $feat1[$label]->overlaps( $feat2[$label] )  ){	        
#	    print STDERR ($label+1)." overlaps ".($label+1)."\t";
#	    print STDERR $feat1[$label]->start.":".$feat1[$label]->end."   ".
#	      $feat2[$label]->start.":".$feat2[$label]->end."\n";
#	    $label++;
#	  }
#	  if ( $label == scalar( @feat1 ) ){
#	    print STDERR "approximate MATCH between $id and $id2 features, skipping $id\n";
#	  }		
#	}
#      }
#      
#    }

    # make MiniEst2Genome runnables
    # to repmask or not to repmask?    
    my $e2g = new Bio::EnsEMBL::Pipeline::Runnable::MiniEst2Genome(
								   '-genomic'  => $genomic,
								   '-features' => \@{$final_ests{$id}},
								   '-seqfetcher' => $self->seqfetcher,
								   '-analysis' => $self->analysis
								  );
    $self->runnable($e2g);
    $rcount++;
  
    # store in a hash of arrays the features put in a MiniEst2Genome
    #$accepted_ests{$id} = $final_ests{$id};
  }

  print STDERR "number of e2gs: $rcount\n";  
  print STDERR "rejected $single single feature ests\n";
  print STDERR "rejected $multi multi feature ests\n";
}


=head2 run

  Arg [1]    : none 
  Example    : $runnable->run
  Description: runs the list of est2genome runnables generated in fetch_input and
               the converts output to remapped genes.
  Returntype : none
  Exceptions : Thrown if there are no runnables to run.
  Caller     : run_RunnableDB

=cut

sub run {
  my ($self) = @_;

  $self->throw("Can't run - no runnable objects") unless defined($self->runnable);
  
  foreach my $runnable($self->runnable) {
    $runnable->run;
  }

  $self->convert_output;

}




=head2 convert_output

  Arg [1]    : none
  Example    : $self->convert_output()
  Description: Converts est2genome output into an array of genes remapped into genomic coordinates
  Returntype : Nothing, but $self->{_output} contains remapped genes
  Exceptions : none
  Caller     : run

=cut

sub convert_output {
  my ($self) = @_;
  my $count  = 1;
  my @genes;

  # make an array of genes for each runnable
  foreach my $runnable ($self->runnable) {
    my @results = $runnable->output;
    #print STDERR "runnable produced ".@results." results\n";
    my @g = $self->make_genes($count, \@results);
    #print STDERR "have made ".@g." genes\n";
    $count++;
    push(@genes, @g);
  }

  my @remapped = $self->remap_genes(@genes);	
  $self->output(@remapped);
}

=head2 make_genes

  Arg [1]    : int $count: integer, 
  Arg [2]    : listref of Bio::EnsEMBL::SeqFeatures with exon sub_SeqFeatures
  Example    : $self->make_genes($count, $genetype, \@results) 
  Description: converts the output from MiniEst2Genome into Bio::EnsEMBL::Genes in
               Slice coordinates. The genes have type exonerate_e2g, 
               and have $analysis_obj attached. Each Gene has a single Transcript, 
               which in turn has Exons(with supporting features) and a Translation
  Returntype : array of Bio::EnsEMBL::Gene
  Exceptions : 
  Caller     : 

=cut

sub make_genes {
  my ($self, $count, $results) = @_;
  my $slice = $self->vcontig;
  my $genetype = 'exonerate_e2g';
  my @genes;
  
  foreach my $tmpf(@$results) {
    my $gene   = new Bio::EnsEMBL::Gene;
    $gene->type($genetype);
    $gene->temporary_id($self->input_id . ".$genetype.$count");

    my $transcript = $self->make_transcript($tmpf, $self->vcontig, $genetype, $count);
    $gene->analysis($self->analysis);
    $gene->add_Transcript($transcript);
    $count++;

    # and store it
    push(@genes,$gene);
  }
  return @genes;

}

=head2 make_transcript

 Title   : make_transcript
 Usage   :
 Function: 
 Example :
 Returns : 
 Args    :


=cut

sub make_transcript{
  my ($self, $gene, $slice, $genetype, $count) = @_;
  $genetype = 'unspecified' unless defined ($genetype);
  $count = 1 unless defined ($count);

  unless ($gene->isa ("Bio::EnsEMBL::SeqFeatureI"))
    {print "$gene must be Bio::EnsEMBL::SeqFeatureI\n";}
  

  my $transcript   = new Bio::EnsEMBL::Transcript;
  $transcript->temporary_id($slice->id . ".$genetype.$count");

  my $translation  = new Bio::EnsEMBL::Translation;    
  $translation->temporary_id($slice->id . ".$genetype.$count");

  $transcript->translation($translation);

  my $excount = 1;
  my @exons;
     
  foreach my $exon_pred ($gene->sub_SeqFeature) {
    # make an exon
    my $exon = new Bio::EnsEMBL::Exon;
    
    $exon->temporary_id($slice->id . ".$genetype.$count.$excount");
    $exon->contig_id($slice->id);
    $exon->start($exon_pred->start);
    $exon->end  ($exon_pred->end);
    $exon->strand($exon_pred->strand);
    
    $exon->phase($exon_pred->phase);
    $exon->end_phase( $exon_pred->end_phase );
    $exon->attach_seq($slice);
    $exon->score($exon_pred->score);
    $exon->adaptor($self->estdb->get_ExonAdaptor);
    # sort out supporting evidence for this exon prediction
    foreach my $subf($exon_pred->sub_SeqFeature){
 
      $subf->feature1->analysis($self->analysis);
	
     
      $subf->feature2->analysis($self->analysis);
      
      $exon->add_supporting_features($subf);
    }
    
    push(@exons,$exon);
    
    $excount++;
  }
  
  if ($#exons < 0) {
    print STDERR "Odd.  No exons foundn";
  } 
  else {
    
#    print STDERR "num exons: " . scalar(@exons) . "\n";

    if ($exons[0]->strand == -1) {
      @exons = sort {$b->start <=> $a->start} @exons;
    } else {
      @exons = sort {$a->start <=> $b->start} @exons;
    }
    
    foreach my $exon (@exons) {
      $transcript->add_Exon($exon);
    }
    
    $translation->start_exon($exons[0]);
    $translation->end_exon  ($exons[$#exons]);
    
    if ($exons[0]->phase == 0) {
      $translation->start(1);
    } elsif ($exons[0]->phase == 1) {
      $translation->start(3);
    } elsif ($exons[0]->phase == 2) {
      $translation->start(2);
    }
    
    $translation->end  ($exons[$#exons]->end - $exons[$#exons]->start + 1);
  }
  
  return $transcript;
}


=head2 remap_genes

    Title   :   remap_genes
    Usage   :   $self->remap_genes(@genes)
    Function:   Remaps predicted genes into genomic coordinates
    Returns :   array of Bio::EnsEMBL::Gene
    Args    :   Bio::EnsEMBL::Virtual::Contig, array of Bio::EnsEMBL::Gene

=cut

sub remap_genes {
  my ($self, @genes) = @_;
  my $slice = $self->vcontig;
  my @remapped;
  
 GENEMAP:
  foreach my $gene(@genes) {
    #     print STDERR "about to remap " . $gene->temporary_id . "\n";
    my @t = $gene->get_all_Transcripts;
    my $tran = $t[0];
    eval {
      $gene->transform;
      # need to explicitly add back genetype and analysis.
      $gene->type($gene->type);
      $gene->analysis($gene->analysis);
      
      # temporary transfer of exon scores. Cannot deal with stickies so don't try
      
      my @oldtrans = $gene->get_all_Transcripts;
      my @oldexons  = $oldtrans[0]->get_all_Exons;
      
      my @newtrans = $gene->get_all_Transcripts;
      my @newexons  = $newtrans[0]->get_all_Exons;
      
      if($#oldexons == $#newexons){
	# 1:1 mapping; each_Exon gives ordered array of exons
	foreach( my $i = 0; $i <= $#oldexons; $i++){
	  $newexons[$i]->score($oldexons[$i]->score);
	}
      }
      
      else{
	$self->warn("cannot transfer exon scores for " . $gene->id . "\n");
      }
      
      push(@remapped,$gene);
      
    };
    if ($@) {
      print STDERR "Couldn't reverse map gene " . $gene->temporary_id . " [$@]\n";
    }
   }

  return @remapped;
}


=head2 _print_FeaturePair

    Title   :   print_FeaturePair
    Usage   :   $self->_print_FeaturePair($pair)
    Function:   Prints attributes of a Bio::EnsEMBL::FeaturePair
    Returns :   Nothing
    Args    :   A Bio::EnsEMBL::FeaturePair

=cut

sub _print_FeaturePair {
  my ($self,$pair) = @_;
  
  print $pair->seqname . "\t" . $pair->start . "\t" . $pair->end . "\t" . 
    $pair->score . "\t" . $pair->strand . "\t" . $pair->hseqname . "\t" . 
      $pair->hstart . "\t" . $pair->hend . "\t" . $pair->hstrand . "\n";
}

=head2 output

    Title   :   output
    Usage   :   $self->output
    Function:   Returns output from this RunnableDB
    Returns :   Array of Bio::EnsEMBL::Gene
    Args    :   None

=cut

sub output {
   my ($self,@feat) = @_;

   if (!defined($self->{'_output'})) {
     $self->{'_output'} = [];
   }
    
   if(@feat){
     push(@{$self->{'_output'}},@feat);
   }

   return @{$self->{'_output'}};
}

=head2 vcontig

 Title   : vcontig
 Usage   : $obj->vcontig($newval)
 Function: 
 Returns : value of vcontig
 Args    : newvalue (optional)

=head2 estfile

 Title   : estfile
 Usage   : $obj->estfile($newval)
 Function: 
 Returns : value of estfile
 Args    : newvalue (optional)


=cut

sub estfile {
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'_estfile'} = $value;
    }
    return $obj->{'_estfile'};

}

=head2 blast

 Title   : blast
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub blast{
   my ($self, @allids) = @_;

   print STDERR "retrieving ".scalar(@allids)." EST sequences\n";
   #print STDERR "for Ids:\n";
   #foreach my $id (@allids){
   #  print STDERR $id." ";
   #}
   #print STDERR "\n";
      
   my $time1 = time();
   my @estseq = $self->get_Sequences(\@allids);
   my $time2 = time();
   print STDERR "SeqFetcher time: user = ".($time2 - $time1)."\n";
   #print STDERR "SeqFetcher time: user = ".($time2[0] - $time1[0])."\tsystem = ".($time2[1] - $time1[1])."\n";

   if ( !scalar(@estseq) ){
     $self->warn("Odd - no ESTs retrieved\n");
     return ();
   }

   print STDERR scalar(@estseq) . " ests retrieved\n";

   my $numests = scalar(@estseq);

   my $blastdb = $self->make_blast_db(@estseq);

   my @features = $self->run_blast($blastdb, $numests);


   unlink $blastdb;
   unlink $blastdb.".csq";
   unlink $blastdb.".nhd";
   unlink $blastdb.".ntb";
   # empty seq array
   @estseq = ();

   return @features;
 }

=head2 

 Title   : get_Sequences
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub get_Sequences {
  my ($self, $allids) = @_;
  my @estseq;

 ACC:
  foreach my $acc(@$allids) {
    my $seq;

#    if (defined($self->{'_seq_cache'}{$acc})){
#      push (@estseq, $seq);
#      next ACC;
#    }

    #print STDERR "getting sequence for $acc\n";
    eval{
      $seq = $self->seqfetcher->get_Seq_by_acc($acc);
    };
    if(!defined $seq){
      my $msg = "Problem fetching sequence for $acc\n";
      if(defined $@){ $msg .= "$@\n"; }
      $self->warn($msg);
    }
    else {
#      $self->{'_seq_cache'}{$acc} = $seq;
      push(@estseq, $seq);
    }

    #if ( $seq ){
    # print STDERR "ID: ".$seq->display_id."\n";
    # print STDERR $seq->seq."\n";
    #}



  }

  return (@estseq);

}

=head2 

 Title   : make_blast_db
 Usage   : $self->make_blast_db(@seq)
 Function: creates a wublastn formatted database from @seq
 Example :
 Returns : name of blast dbfile
 Args    : @seq: Array of Bio::Seq


=cut

sub make_blast_db {
    my ($self, @seq) = @_;

    my $blastfile = '/tmp/FEE_blast.' . $$ . '.fa';
    my $seqio = Bio::SeqIO->new('-format' => 'Fasta',
				'-file'   => ">$blastfile");

    foreach my $seq (@seq) {

      $seqio->write_seq($seq);
    }
    
    close($seqio->_filehandle);
    
    my $status = system("pressdb $blastfile");
    
    return $blastfile;
  }


=head2 

 Title   : run_blast
 Usage   : $self->run_blast($db, $numests)
 Function: runs blast between $self->vc and $db, allowing a max of $numests alignments. parses output
 Example :
 Returns : array of Bio:EnsEMBL::FeaturePair representing blast hits
 Args    : $estdb: name of wublast formatted database; $numests: number of ests in the database


=cut

sub run_blast {
  my ($self, $estdb, $numests) = @_;
  my @results;
  
  # prepare genomic seq
  my $seqfile  = "/tmp/FEE_genseq." . $$ . ".fa";
  my $blastout = "/tmp/FEE_blastout." . $$ . ".fa";;
  my $seqio = Bio::SeqIO->new('-format' => 'Fasta',
			      -file   => ">$seqfile");
  $seqio->write_seq($self->vcontig);
  close($seqio->_filehandle);

  # set B here to make sure we can show an alignment for every EST
  my $command   = "wublastn $estdb $seqfile B=" . $numests . " -hspmax 1000  2> /dev/null >  $blastout";
  #print STDERR "Running BLAST:\n";
  print STDERR "$command\n";
  my $status = system( $command );
  
  my $blast_report = new Bio::EnsEMBL::Pipeline::Tools::BPlite(-file=>$blastout);

 HIT:
  while(my $hit = $blast_report->nextSbjct) {
    my $estname;

    while (my $hsp = $hit->nextHSP) {
      if(defined $estname && $estname ne $hsp->subject->seqname){
	$self->warn( "trying to switch querynames halfway through a blast hit for $estname - big problem!\n");
	next HIT;
      }
      else{
	$estname = $hsp->subject->seqname;
      }

      my $genomic = new Bio::EnsEMBL::SeqFeature (
						 -start       => $hsp->query->start,
						 -end         => $hsp->query->end,
						 -seqname     => $hsp->query->seqname,
						 -strand      => $hsp->query->strand,
						 -score       => $hsp->query->score,
					
						);
      
      my $est = new Bio::EnsEMBL::SeqFeature  ( -start       => $hsp->subject->start,
						-end         => $hsp->subject->end,
						-seqname     => $hsp->subject->seqname,
						-strand      => $hsp->subject->strand,
						-score       => $hsp->subject->score,
					
					      );

      # if both genomic and est strands are the same, convention is to set both to be 1
      # if they differ, convention is to set genomic strand to -1, est strand to 1
      if($genomic->strand == $est->strand){
	$genomic->strand(1);
	$est->strand(1);
      }
      else{
	$genomic->strand(-1);
	$est->strand(1);
      }
      #create featurepair
      my $fp = new Bio::EnsEMBL::FeaturePair  (-feature1 => $genomic,
					       -feature2 => $est) ;
      #print STDERR $fp->gffstring."\n";
      if ($fp) {
	push (@results, $fp);
      }
    }
  }
  
  unlink $blastout;
  unlink $seqfile;
  
  return @results; 
    
}

=head2 make_seqfetcher

 Title   : make_seqfetcher
 Usage   :
 Function: makes a Bio::EnsEMBL::SeqFetcher to be used for fetching EST sequences. If 
           $est_genome_conf{'est_index'} is specified in EST_conf.pl, then a Getseqs 
           fetcher is made, otherwise it will be Pfetch. NB for analysing large numbers 
           of ESTs eg all human ESTs, pfetch is far too slow ...
 Example :
 Returns : Bio::EnsEMBL::SeqFetcher
 Args    :


=cut

sub make_seqfetcher {
  print STDERR "making a seqfetcher\n";
  my ( $self ) = @_;
  my $index   = $EST_INDEX;

  my $seqfetcher;
  if(defined $index && $index ne ''){
    my @db = ( $index );
    #$seqfetcher = new Bio::EnsEMBL::Pipeline::SeqFetcher::Getseqs('-db' => \@db,);
  
    ## SeqFetcher to be used with 'indicate' indexing:
    $seqfetcher = new Bio::EnsEMBL::Pipeline::SeqFetcher::OBDAIndexSeqFetcher('-db' => \@db, );
    
  }
  #else{
  #  # default to Pfetch
  #  $seqfetcher = new Bio::EnsEMBL::Pipeline::SeqFetcher::Pfetch;
  #}
  else{
    $self->throw( "cannot create a seqfetcher from $index");
  }

  return $seqfetcher;

}

sub make_analysis {
  my ($self) = @_;
  
  # get the appropriate analysis from the AnalysisAdaptor
  my $anaAdaptor = $self->db->get_AnalysisAdaptor;
  my @analyses = $anaAdaptor->fetch_by_logic_name($self->genetype);
  
  my $analysis_obj;
  if(scalar(@analyses) > 1){
    $self->throw("panic! > 1 analysis for " . $self->genetype . "\n");
  }
  elsif(scalar(@analyses) == 1){
    $analysis_obj = $analyses[0];
  }
  else{
    # make a new analysis object
    $analysis_obj = new Bio::EnsEMBL::Analysis
      (-db              => 'dbEST',
       -db_version      => 1,
       -program         => $self->genetype,
       -program_version => 1,
       -gff_source      => $self->genetype,
       -gff_feature     => 'gene',
       -logic_name      => $self->genetype,
       -module          => 'FilterESTs_and_E2G',
      );
  }

  $self->analysis($analysis_obj);

}

sub genetype {
  my ($self) = @_;
  return 'exonerate_e2g';
}

1;
