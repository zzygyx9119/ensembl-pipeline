#
# Object for building genes
#
# Cared for by Michele Clamp  <michele@sanger.ac.uk>
#
# Copyright Michele Clamp
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Pipeline::GeneBuilder

=head1 SYNOPSIS

# This is the main analysis database

my $db = new Bio::EnsEMBL::DBSQL::Obj(-host   => 'obi-wan',
				      -user   => 'ensro',
				      -dbname => 'ens500',
				      );

# Fetch a clone and its contigs from the database
my $clone       = $db   ->get_Clone($clone);
my @contigs     = $clone->get_all_Contigs;

# The genebuilder object will fetch all the features from the contigs
# and use them to first construct exons, then join those exons into
# exon pairs.  These exon apris are then made into transcripts and
# finally all overlapping transcripts are put together into one gene.


my $genebuilder = new Bio::EnsEMBL::Pipeline::GeneBuilder
    (-contigs => \@contigs);

my @genes       = $genebuilder->build_Genes;

# After the genes are built they can be used to order the contigs they
# are on.

my @contigs     = $genebuilder->order_Contigs;


=head1 DESCRIPTION

Takes in contigs and returns genes.  The procedure is currently
reimplementing the TimDB method of building genes where genscan exons
are confirmed by similarity features which are then joined together
into exon pairs.  An exon pair is constructed as follows :

  ---------          --------    genscan exons
    -------          ----->      blast hit which spans an intron
    1     10        11    22        

For an exon pair to make it into a gene there must be at least 2 blast
hits (features) that span across an intron.  This is called the
coverage of the exon pair.

After all exon pairs have been generated for all the genscan exons
there is a recursive routine (_recurseTranscripts) that looks for all
exons that are the start of an exon pair with no preceding exons.  The
exon pairs are followed recursively (including alternative splices) to
build up full set of transcripts.

To generate the genes the transcripts are grouped together into sets
with overlapping exons.

=head1 CONTACT

Describe contact details here

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut

# Let the code begin...

package Bio::EnsEMBL::Pipeline::GeneBuilder;

use Bio::EnsEMBL::Pipeline::ExonPair;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Gene;
use Bio::EnsEMBL::Analysis;
use Bio::EnsEMBL::Slice;
use Bio::EnsEMBL::Utils::GTF_handler;
use Bio::EnsEMBL::SeqFeature;
use Bio::EnsEMBL::Root;
use Bio::EnsEMBL::TranscriptFactory;
use Bio::EnsEMBL::Pipeline::GeneConf qw (
					 TRANSCRIPT_ID_SUBSCRIPT
					 GB_MIN_GENSCAN_EXONS
					 GB_GENSCAN_MAX_INTRON
					 GB_TARGETTED_GW_GENETYPE
					 GB_SIMILARITY_GENETYPE
					 GB_COMBINED_GENETYPE
					 GB_MIN_FEATURE_SCORE
					 GB_MIN_FEATURE_LENGTH
					 GB_INPUTID_REGEX
					);
use vars qw(@ISA);
use strict;

@ISA = qw(Bio::EnsEMBL::Root);


############################################################

sub new {
    my ($class,@args) = @_;

    my $self = $class->SUPER::new(@args);

    my ($slice,$input_id) = $self->_rearrange([qw(SLICE INPUT_ID)],
					      @args);

    $self->throw("Must input a slice to GeneBuilder") unless defined($slice);
    $self->slice($slice);
    $self->{'_final_genes'}          = [];
    $self->{'_gene_types'}           = [];
    $self->gene_types($GB_COMBINED_GENETYPE);
    $self->gene_types($GB_TARGETTED_GW_GENETYPE);
    $self->gene_types($GB_SIMILARITY_GENETYPE);

    unless ( $input_id =~ /$GB_INPUTID_REGEX/ ){
      $self->throw("format of the input is not defined in GeneConf::GB_INPUTID_REGEX = $GB_INPUTID_REGEX");
    }
    $self->input_id($input_id);

    return $self;
}

############################################################

=head2 input_id

 Function: get/set for input id
 Returns : string
 Args    : string (it expects a string of the format chr_name.start_coord-end_coord

=cut
  
sub input_id {
  my ($self,$id) = @_;
  
  if (defined($id)) {
    $self->{_input_id} = $id;
  }
  return $self->{_input_id};
}

############################################################

=head2 build_Genes

 Example    : my @genes = $self->build_Genes
 Description: builds genes. It is like the run method in Runnables. It calls everything that needs to be done.
 Returns    : none
 Args       : none
 Caller     : Bio::EnsEMBL::Pipeline::RunnableDB::Gene_Builder

=cut

sub build_Genes {
    my ($self) = @_;

    print STDERR "Building genes\n";

    # get all genes of type defined in gene_types() on this slice
    $self->get_Genes;
    print STDERR "Number of genewise and combined transcripts " . scalar($self->genewise_combined_Transcripts) . "\n\n";

    # get all Genscan predictions on this slice
    $self->get_Predictions;
    print STDERR "Number of ab initio predictions ". scalar($self->predictions)  . "\n";

    # get all the dna/protein align features from the pre-computes pipeline on this slice
    $self->get_Similarities;
    print STDERR "\nNumber of similarity features ". scalar($self->features) . "\n";
    
    # get all exons from the PredictionTranscripts, take only exons with overlapping similarity features, which
    # are incorporated as supporting evidence
    $self->make_Exons;
    
    # pair up the exons according to consecutive overlapping supporting evidence
    $self->make_ExonPairs;
    
    # link exon-pairs recursively according to shared evidence to form transcripts
    # resulting transcripts are stored as
    $self->link_ExonPairs;
    
    $self->filter_Transcripts;
    
    $self->make_Genes;

    # this clusters transcripts into genes
    $self->recluster_Transcripts;

    print STDERR "Out of build Genes...\n";

}



############################################################


=head2 get_Genes

 Description: retrieves genewise and combined gene annotations with supporting evidence. 
              Splits transcripts with very long introns, discards transcripts with strand problems etc.
 ReturnType : none, but $self->genewise_combined_Transcripts is filled
 Args       : none

=cut

sub get_Genes {
  my ($self) = @_;
  my @transcripts;
  my $db = $self->genes_db;
  my $sa = $db->get_SliceAdaptor;
  
  my $input_id = $self->input_id;
  $input_id =~/$GB_INPUTID_REGEX/;
  my $chr   = $1;
  my $start = $2;
  my $end   = $3;
  my $slice = $sa->fetch_by_chr_start_end($chr,$start,$end);
  
  my @unchecked_genes;
  
  foreach my $type ($self->gene_types) {
    push(@unchecked_genes, @{$slice->get_Genes_by_type($type, 'evidence')});
  }
  
  foreach my $gene (@unchecked_genes) {
    
  TRANSCRIPT:
    foreach my $tran (@{$gene->get_all_Transcript}) {
      
      # set temporary_id to be dbID
      $tran->{'temporary_id'} = ($tran->dbID) unless (defined $tran->{'temporary_id'} && $tran->{'temporary_id'} ne '');
      
      # my @valid_transcripts = $self->validate_transcript($t);
      # next TRANSCRIPT unless scalar(@valid_transcripts);
      
      unless ( $self->_check_Transcript( $tran ) ){
	next TRANSCRIPT;
      }
      
      my $previous_exon;
    EXON:
      foreach my $exon (@{$tran->get_all_Exons}) {
	
	$self->warn("no contig id\n") unless defined $exon->contig_id;
	if(!defined $exon->contig_id){ 
	  $exon->contig_id("sticky"); 
	}
	
	# check contig consistency  
	if ($previous_exon){
	  # don't trust StickyExons, they won't necessarily tell you the truth
	  unless( $previous_exon->isa('Bio::EnsEMBL::StickyExon') || $exon->isa('Bio::EnsEMBL::StickyExon') ){
	    if ( !( $previous_exon->seqname eq $exon->seqname ) ){
	      print STDERR "transcript ".$tran->dbID." is partly outside the contig, skipping it...\n";
	      next TRANSCRIPT;
	    }
	  }
	}
	$exon->{'temporary_id'} = ($exon->dbID) unless (defined $exon->{'temporary_id'} && $exon->{'temporary_id'} ne '');
	$previous_exon = $exon;
	
      }				# end of EXON
      
      push(@transcripts, $tran);
      
    }				# end TRANSCRIPT
  }
  
  $self->genewise_combined_Transcripts(@transcripts);
}


############################################################

# This is a somewhat kludgy attempt to deal with gene repeats
# If, out of a set of transcripts, one transcript encompasses both
# the start and end of other transcripts it is suspected of leaping 
# between gene repeats and is deleted.
#
# I suspect this will introduce extra fragmentation but it should deal with 
# some of the pathological cases

sub filter_Transcripts {
  my ($self) = @_;
  
  #    print STDERR "Filtering transcripts\n";
  my @transcripts = $self->get_all_Transcripts;
  
  my @new;
  
  push(@new,@transcripts);
    # We now also have to filter transcripts to trim off the satellite single exon genscan genes that
    # happen at the end of genewise genes.

    my @exons = $self->prediction_exons;
    
    my @new2;

    print STDERR "Starting second filter\n";
    foreach my $tran (@new) {
	my @gexons = @{ $tran->get_all_Exons };

#	print ("Looking at " . $tran->{'temporary_id'} . "\t" . $#gexons . "\n");
	if ($#gexons == 0) {
	    # find nearest 5' exon
	    my $exon5;
	    my $exon3;
	    my $gap = 10000000000;
	    my $found_genewise = 0;

#	    print STDERR "\nFound single exon gene " . $tran->{'temporary_id'} . "\n";
#	    $self->print_Exon($gexons[0]);

	  EX2: foreach my $ex (@exons) {
	      next EX2 if ($ex == $gexons[0]);

#		  $self->print_Exon($ex);

	      if ($ex->strand == $gexons[0]->strand &&
		  ($gexons[0]->start - $ex->end)  > 0 &&
		  ($gexons[0]->start - $ex->end) < $gap) {
		  $exon5 = $ex;
		  $gap = ($gexons[0]->start - $ex->end);
	      }
#	      $self->print_Exon($ex);

	  }
	    if (defined($exon5)) {
#		print STDERR "Found exon5\n";
#		$self->print_Exon($exon5);
		# get evidence
		my @evidence = @{ $exon5->get_all_supporting_features };
		
		# any of it genewise?
		
		foreach my $ev (@evidence) {
		  foreach my $type ($self->genewise_types) {
		    if ($ev->source_tag eq $type) {
#		      print ("Tag " . $ev->source_tag . "\n");
		      # don't use transcript
		      $found_genewise = 1;
		    }
		  }
		
		}
	      }
	    $gap = 1000000000000;

	  EX3: foreach my $ex (@exons) {
	      next EX3 if ($ex == $gexons[0]);
#		  print STDERR "\t Gap $gap";
#		  $self->print_Exon($ex);

	      # find nearest 3' exon
	      if ($ex->strand == $gexons[0]->strand &&
		  ($ex->start - $gexons[0]->end)  > 0 &&
		  ($ex->start - $gexons[0]->end) < $gap) {
		  $exon3 = $ex;
		  $gap = ($ex->start - $gexons[0]->end);
	      }
#	    print STDERR "\t Gap $gap";
#	    $self->print_Exon($ex);

	  }

	    if (defined($exon3)) {
		# get evidence
		my @evidence = @{ $exon3->get_all_supporting_features };
		
		# any of it genewise?
		  
		  foreach my $ev (@evidence) {
#		      print ("Tag " . $ev->source_tag . "\n");
		      if ($ev->source_tag eq "genewise") {
			  # don't use transcript
			  $found_genewise = 1;
		      }
		  }
		  
	    }

	    # else add to the array	
	    if ($found_genewise == 0) {
		push(@new2,$tran);
	    }

	} else {
	    push(@new2,$tran);
	}
    }

    $self->{'_transcripts'} = [];

    push(@{$self->{'_transcripts'}},@new2);

}

###########################################################c

=head2 make_Genes

 Title   : make_Genes
 Usage   : my @genes = $self->make_Genes(@transcript)
 Function: Turns a set of transcripts into an array of genes
           Transcripts with shared exons go into the same gene
 Example : 
 Returns : Array of Bio::EnsEMBL::Gene
 Args    : Array of Bio::EnsEMBL::Transcript

=cut

sub make_Genes {
  my ($self) = @_;
  
  my @genes;
  
  my $trancount = 1;
  my $genecount = 1;
  my $contigid = $self->contig->id;
  
  my @transcripts = $self->get_all_Transcripts;
  push(@transcripts,$self->genewise);
  
  # reject non translators before we try clustering
  # MC also check for folded transcripts.

  my $valid = 1;
  
 TRANSCRIPT:
  foreach  my $tran (@transcripts) {
    eval{
      if ($tran->translate->seq !~ /\*/) {
	$valid = 1;
      }
      else{
	print STDERR "ERROR: Doesn't translate " . $tran->{'temporary_id'} . ". Skipping [$@]\n";
	$valid = 0;
      }
    };
    if ($@) {
      print STDERR "ERROR: Can't translate " . $tran->{'temporary_id'} . ". Skipping [$@]\n";
      $valid = 0;
      next TRANSCRIPT;
    }

    # Now check for folded transcripts;

    my $current = 0;
    my @exons = @{$tran->get_all_Exons};
    if ($#exons > 0) {
      my $i;
      for ($i = 1; $i < $#exons; $i++) {
        if ($exons[0]->strand == 1) {
          if ($exons[$i]->start < $exons[$i-1]->end) {
              print STDERR "ERROR:  Transcript folds back on itself. Tran : " . $tran->{'temporary_id'} . "\n";
              $valid = 0;
          } 
        } elsif ($exons[0]->strand == -1) {
          if ($exons[$i]->end > $exons[$i-1]->start) {
              print STDERR "ERROR:  Transcript folds back on itself. Tran : " . $tran->{'temporary_id'} . "\n";
              $valid = 0;
          } 
        } else {
          print STDERR "EEEK:In transcript  " . $tran->{'temporary_id'} . " No strand for exon - can't check for folded transcript\n";

          $valid = 0;
        }
      }
    }

    # if we get here, the transcript should be fine
    next TRANSCRIPT unless $valid;
    
    $trancount++;
    
    my $found = undef;
    
  GENE: foreach my $gene (@genes) {
    EXON: foreach my $gene_exon (@{$gene->get_all_Exons}) {
	foreach my $exon (@{$tran->get_all_Exons}) {
	  if ($exon->overlaps($gene_exon)) {
	    if ($exon->strand == $gene_exon->strand) {
	      $found = $gene;
	      last GENE;
	    } 
	    else {
	      print STDERR "ERROR: Overlapping exons on opposite strands " . $exon->{'temporary_id'} . " " . $gene_exon->{'temporary_id'} . " " . $tran->{'temporary_id'} . " " . $gene->{'temporary_id'} . " " . $self->input_id . "\n";
	    }
	  }
	}
      }
    }
    
    if (defined($found)) {
      $found->add_Transcript($tran);
    } 
    else {
      my $gene = new Bio::EnsEMBL::Gene;
      my $geneid = "TMPG_$contigid.$genecount";
      $gene->{'temporary_id'} = ($geneid);
      $genecount++;

      $gene->add_Transcript($tran);
      push(@genes,$gene);
    }
  } # end TRANSCRIPT
  
  # if already rejected non translators could prune gene by gene?
  foreach my $gene(@genes){
    my @newgenes = $self->prune_gene($gene);
    
    # deal with shared exons
    foreach my $gene (@newgenes) {
      $self->prune_Exons($gene);
    }
    
    foreach my $newgene (@newgenes) {
      $self->add_Gene($newgene);
    }
  }
}

############################################################

=head2 recluster_Transcripts

    Title   :   recluster_Transcripts
    Usage   :   $self->recluster_Transcripts
    Function:   Check the clustering of transcripts 
                and make sure all the transcripts that really belong to a single 
                gene have been put into that gene.
                Ultimately to be made part of main clustering algorithm
    Returns :   Nothing
    Args    :   None

=cut

sub recluster_Transcripts{
  my ($self) = @_;
  my $num_old_genes = 0;
  my @transcripts_unsorted;
  foreach my $gene ($self->each_Gene) {
    $num_old_genes++;
    foreach my $tran ( @{ $gene->get_all_Transcripts} ) {
      push(@transcripts_unsorted, $tran);
    }
  }

  # flush old genes
  $self->flush_Genes;
  
  my @transcripts = sort by_transcript_high @transcripts_unsorted;
  my @clusters;

  # clusters transcripts by whether or not any exon overlaps with an exon in 
  # another transcript (came from original prune in GeneBuilder)
  foreach my $tran (@transcripts) {
    my @matching_clusters;
  CLUSTER: foreach my $cluster (@clusters) {
      foreach my $cluster_transcript (@$cluster) {
        foreach my $exon1 (@{$tran->get_all_Exons}) {
	  
          foreach my $cluster_exon (@{$cluster_transcript->get_all_Exons}) {
            if ($exon1->overlaps($cluster_exon) && $exon1->strand == $cluster_exon->strand) {
              push (@matching_clusters, $cluster);
              next CLUSTER;
            }
          }
        }
      }
    }
    
    if (scalar(@matching_clusters) == 0) {
      my @newcluster;
      push(@newcluster,$tran);
      push(@clusters,\@newcluster);
    } 
    elsif (scalar(@matching_clusters) == 1) {
      push @{$matching_clusters[0]}, $tran;
      
    } 
    else {
      # Merge the matching clusters into a single cluster
      my @new_clusters;
      my @merged_cluster;
      foreach my $clust (@matching_clusters) {
        push @merged_cluster, @$clust;
        foreach my $trans (@$clust) {
        } 
      }
      push @merged_cluster, $tran;
      foreach my $trans (@merged_cluster) {
      } 
      push @new_clusters,\@merged_cluster;
      # Add back non matching clusters
      foreach my $clust (@clusters) {
        my $found = 0;
      MATCHING: foreach my $m_clust (@matching_clusters) {
          if ($clust == $m_clust) {
            $found = 1;
            last MATCHING;
          }
        }
        if (!$found) {
          push @new_clusters,$clust;
        }
      }
      @clusters =  @new_clusters;
    }
  }
  
  # safety and sanity checks
  $self->check_Clusters(scalar(@transcripts), $num_old_genes, \@clusters);

  # make and store genes
  
  foreach my $cluster(@clusters){
    my $gene = new Bio::EnsEMBL::Gene;
    foreach my $transcript(@$cluster){
      $gene->add_Transcript($transcript);
    }

    # prune out duplicate exons
    $self->prune_Exons($gene);
    
    $self->add_Gene($gene);
  }
  
}

############################################################

sub check_Clusters{
  my ($self, $num_transcripts, $num_old_genes, $clusters) = @_;
  #Safety checks
  my $ntrans = 0;
  my %trans_check_hash;
  foreach my $cluster (@$clusters) {
    $ntrans += scalar(@$cluster);
    foreach my $trans (@$cluster) {
      if (defined($trans_check_hash{"$trans"})) {
        $self->throw("Transcript " . $trans->dbID . " added twice to clusters\n");
      }
      $trans_check_hash{"$trans"} = 1;
    }
    if (!scalar(@$cluster)) {
      $self->throw("Empty cluster");
    }
  }
  if ($ntrans != $num_transcripts) {
    $self->throw("Not all transcripts have been added into clusters $ntrans and " . $num_transcripts. " \n");
  } 
  #end safety checks
  
  if (scalar(@$clusters) < $num_old_genes) {
    $self->warn("Reclustering reduced number of genes from " . 
		$num_old_genes . " to " . scalar(@$clusters). "\n");
  } elsif (scalar(@$clusters) > $num_old_genes) {
    $self->warn("Reclustering increased number of genes from " . 
		$num_old_genes . " to " . scalar(@$clusters). "\n");
  }

}


############################################################

sub by_transcript_high {
  my $alow;
  my $blow;
  my $ahigh;
  my $bhigh;

  if ($a->start_exon->strand == 1) {
    $alow = $a->start_exon->start;
    $ahigh = $a->end_exon->end;
  } else {
    $alow = $a->end_exon->start;
    $ahigh = $a->start_exon->end;
  }

  if ($b->start_exon->strand == 1) {
    $blow = $b->start_exon->start;
    $bhigh = $b->end_exon->end;
  } else {
    $blow = $b->end_exon->start;
    $bhigh = $b->start_exon->end;
  }

  if ($ahigh != $bhigh) {
    return $ahigh <=> $bhigh;
  } else {
    return $alow <=> $blow;
  }
}



############################################################

sub prune_Exons {
    my ($self,$gene) = @_;

    my @unique_Exons; 

    # keep track of all unique exons found so far to avoid making duplicates
    # need to be very careful about translation->start_exon and translation->end_exon

    foreach my $tran (@{$gene->get_all_Transcripts}) {
       my @newexons;
       foreach my $exon (@{$tran->get_all_Exons}) {
           my $found;
	   #always empty
           UNI:foreach my $uni (@unique_Exons) {
              if ($uni->start  == $exon->start  &&
                  $uni->end    == $exon->end    &&
                  $uni->strand == $exon->strand &&
		  $uni->phase  == $exon->phase  &&
		  $uni->end_phase == $exon->end_phase
		 ) {
                  $found = $uni;
                  last UNI;
              }
           }
           if (defined($found)) {
              push(@newexons,$found);
	      if ($exon == $tran->translation->start_exon){
		$tran->translation->start_exon($found);
	      }
	      if ($exon == $tran->translation->end_exon){
		$tran->translation->end_exon($found);
	      }
           } else {
              push(@newexons,$exon);
	      push(@unique_Exons, $exon);
           }
	   


         }          
      $tran->flush_Exon;
      foreach my $exon (@newexons) {
         $tran->add_Exon($exon);
      }
   }
}





############################################################
#
# METHODS DEALING WITH PREDICTION TRANSCRIPTS AND FEATURES
# ( first step towards the refactorisation of the GeneBuilder )
#
############################################################ 


=head2 get_Predictions

Description:  gets your favourite ab initio predictions (genscan,genefinder,fgenesh,genecooker...8-)
Returns : none, but $self->predictions is filled
Args    : none

=cut
  
sub get_Predictions {
  my ($self) = @_;
  my @checked_predictions;
  foreach my $prediction ( @{ $self->slice->get_all_PredictionTranscripts } ){
    unless ( $self->_check_Transcript( $prediction ) ){
      next;
    }
    push ( @checked_predictions, $prediction );
  }
  $self->predictions(@checked_predictions);
}

############################################################

=head2 get_Similarities

 Title   : get_Similarities
 Usage   : $self->get_Similarities
 Function: gets similarity features for this region
 Returns : none, but $self->feature is filled
 Args    : none

=cut

sub get_Similarities {
  my ($self) = @_;

  my @features = @{ $self->slice->get_all_SimilarityFeatures('',$GB_MIN_FEATURE_SCORE) };
  
  my %idhash;
  my @other_features;
  
  foreach my $feature (@features) {
    unless ( $idhash{ $feature->hseqname } ){
      $idhash{ $feature->hseqname } = [];
    }
    if ($feature->length > $GB_MIN_FEATURE_LENGTH) {
      if ($feature->isa("Bio::EnsEMBL::BaseAlignFeature")) {
	push( @{ $idhash{ $feature->hseqname } }, $feature );
      }
    }
    else {
      push(@other_features,$feature);
    }
  }
  
  my @merged_features = $self->merge(\%idhash);

  my @newfeatures;
  push(@newfeatures,@merged_features);
  push(@newfeatures,@other_features);
  
  $self->features(@newfeatures);
}
   
############################################################

=head2 make_Exons

 Example : my @exons = $self->make_Exons;
 Function: Turns features into exons with the help of the ab initio predictions

=cut

sub make_Exons {
  my ($self) = @_;
  
  my @exons;
  my @features    = sort { $a->start <=> $b->start } $self->features;
  my @predictions = $self->perdictions;
  my $gscount  = 1;
  
  my $ignored_exons = 0;
  
 PREDICTION:  
  foreach my $prediction (@predictions) {
    my $excount    = 1;
    unless ( @{$prediction->get_all_Exons} ){
      next PREDICTION;
    }
    
  EXON: 
    foreach my $prediction_exon (@{$prediction->get_all_Exons}) {
      
      # Don't include any genscans that are inside a genewise/combined transcript
      foreach my $gene ($self->genewise_combined_Transcripts) {
	my @exons = @{$gene->get_all_Exons};
	@exons = sort {$a->start <=> $b->start} @exons;
	my $g_start  = $exons[0]->start;
	my $g_end    = $exons[$#exons]->end;
	my $g_strand = $exons[0]->strand;
	
	if (!(($g_end < $prediction_exon->start) || $g_start > $prediction_exon->end)) {
	  if ($g_strand == $prediction_exon->strand) {
	    $ignored_exons++;
	    next EXON;
	  }
	}
      }
      my $newexon = $self->_make_Exon($prediction_exon,$excount,"genscan." . $gscount . "." . $excount );
      $newexon->find_supporting_evidence(\@features,1);
      
      # take only the exons that get supporting evidence
      if ( @{ $newexon->get_all_supporting_features } ){
	push(@exons,$newexon);
	$excount++;
      }
    }
    
    $gscount++;
  }
  
  print "\nIgnoring $ignored_exons genscan exons due to overlaps with genewise genes\n";
  $self->prediction_exons(@exons);
}

############################################################

=head2 make_ExonPairs

 Description: Links exons with supporting evidence into ExonPairs

=cut
  
sub  make_ExonPairs {
  my ($self) = @_;
  
  my $gap = 5;  
  my %pairhash;
  my @exons = $self->prediction_exons;
  my @forward;
  my @reverse;
  
 EXON: 
  for (my $i = 0; $i < scalar(@exons)-1; $i++) {
    
    my %idhash;
    my $exon1 = $exons[$i];
    
    my $jstart = $i - 2;  if ($jstart < 0) {$jstart = 0;}
    my $jend   = $i + 2;  if ($jend >= scalar(@exons)) {$jend    = scalar(@exons) - 1;}
    
  J: 
    for (my $j = $jstart ; $j <= $jend; $j++) {
      next J if ($i == $j);
      next J if ($exons[$i]->strand != $exons[$j]->strand);
      next J if ($exons[$i]->{'temporary_id'}  eq $exons[$j]->{'temporary_id'});
      
      my $exon2 = $exons[$j];
      my %doneidhash;
            
      # For the two exons we compare all of their supporting features.
      # If any of the supporting features of the two exons
      # span across an intron a pair is made.
      my @f1 = @{$exon1->get_all_supporting_features};
      @f1 = sort {$b->score <=> $a->score} @f1;
      
    F1: 
      foreach my $f1 (@f1) {
	next F1 if (!$f1->isa("Bio::EnsEMBL::FeaturePair"));
	my @f = @{$exon2->get_all_supporting_features};
	@f = sort {$b->score <=> $a->score} @f;
	
      F2: 
	foreach my $f2 (@f) {
	  next F2 if (!$f2->isa("Bio::EnsEMBL::FeaturePair"));
	  next F1 if (!($f1->isa("Bio::EnsEMBL::FeaturePair")));
	  
	  my @pairs = $self->get_all_ExonPairs;		
	  
	  # Do we have hits from the same sequence
	  # n.b. We only allow each database hit to span once
	  # across the intron (%idhash) and once the pair coverage between
	  # the two exons reaches $minimum_coverage we 
	  # stop finding evidence. (%pairhash)
	  
	  if ($f1->hseqname eq $f2->hseqname &&
	      $f1->strand   == $f2->strand   &&
	      !(defined($idhash{$f1->hseqname})) &&
	      !(defined($pairhash{$exon1}{$exon2}))) {
	    
	    my $ispair = 0;
	    my $thresh = $self->threshold;
	    
	    if ($f1->strand == 1) {
	      if (abs($f2->hstart - $f1->hend) < $gap) {
		
		if (!(defined($doneidhash{$f1->hseqname}))) {
		  $ispair = 1;
		}
	      }
	    } 
	    elsif ($f1->strand == -1) {
	      if (abs($f1->hend - $f2->hstart) < $gap) {
		if (!(defined($doneidhash{$f1->hseqname}))) {
		  $ispair = 1;
		}
	      }
	    }
	    
	    # This checks if the coordinates are consistent if the 
	    # exons are on the same contig
	    if ($ispair == 1) {
	      if ($exon1->contig_id eq $exon2->contig_id) {
		if ($f1->strand == 1) {
		  if ($f1->end >  $f2->start) {
		    $ispair = 0;
		  }
		} 
		else {
		  if ($f2->end >  $f1->start) {
		    $ispair = 0;
		  }
		}
	      }
	    }
	    
	    # We finally get to make a pair
	    if ($ispair == 1) {
	      eval {
		my $check = $self->check_link($exon1,$exon2,$f1,$f2);
		#			    print STDERR "\nPossible pair - checking link - $check ". 
		$exon1->start . "\t" . $exon1->end . "\n";
		
		next J unless $check;
		
		#			    print STDERR "Making new pair " . $exon1->start . " " . 
		#				                              $exon1->end   . " " . 
		#							      $exon2->start . " " . 
		#							      $exon2->end . "\n";
		
		my $pair = $self->makePair($exon1,$exon2,"ABUTTING");
		
		if (defined $pair) {
		  $idhash    {$f1->hseqname} = 1;
		  $doneidhash{$f1->hseqname} = 1;
		  
		  $pair->add_Evidence($f1);
		  $pair->add_Evidence($f2);
		  
		  if ($pair->is_Covered == 1) {
		    $pairhash{$exon1}{$exon2}  = 1;
		  }
		  next EXON;
		}
		
		
	      };
	      if ($@) {
		warn("Error making ExonPair from [" . $exon1->{'temporary_id'} . "][" .$exon2->{'temporary_id'} ."] $@");
	      }
	    }
	  }
	}
      }
    }
  }
  return $self->get_all_ExonPairs;
}

############################################################

=head2 makePair

 Title   : makePair
 Usage   : my $pair = $self->makePair($exon1,$exon2)
 Function:  
 Example : 
 Returns : Bio::EnsEMBL::Pipeline::ExonPair
 Args    : Bio::EnsEMBL::Exon,Bio::EnsEMBL::Exon

=cut

sub makePair {
    my ($self,$exon1,$exon2,$type) = @_;

    if (!defined($exon1) || !defined($exon2)) {
	$self->throw("Wrong number of arguments [$exon1][$exon2] to makePair");
    }

    $self->throw("[$exon1] is not a Bio::EnsEMBL::Exon") unless $exon1->isa("Bio::EnsEMBL::Exon");
    $self->throw("[$exon2] is not a Bio::EnsEMBL::Exon") unless $exon2->isa("Bio::EnsEMBL::Exon");

    my $tmppair = new Bio::EnsEMBL::Pipeline::ExonPair(-exon1 => $exon1,
						       -exon2 => $exon2,
						       -type  => $type,
						       );
    $tmppair->add_coverage;

    my $found = 0;

    foreach my $p ($self->get_all_ExonPairs) {
	if ($p->compare($tmppair) == 1) {
	    $p->add_coverage;
	    $tmppair = $p;
	    $found = 1;
	}
    }

    if ($found == 0 && $self->check_ExonPair($tmppair)) {
	$self->add_ExonPair($tmppair);
	return $tmppair;
    }

    return;

}

############################################################


=head2 merge

 Description: wicked meethod that merges two or more homol features into one if they are close enough together
  Returns   : nothing
  Args      : none

=cut

sub merge {
  my ($self,$feature_hash,$overlap,$query_gap,$homol_gap) = @_;
  
  $overlap   = 20  unless $overlap;
  $query_gap = 15  unless $query_gap;
  $homol_gap = 15  unless $homol_gap;
  
  my @mergedfeatures;
  
  foreach my $id (keys %{ $feature_hash }) {
    
    my $count = 0;
    my @newfeatures;
    my @features = @{$feature_hash->{$id}};
    
    @features = sort { $a->start <=> $b->start} @features;
    
    # put the first feature in the new array;
    push(@newfeatures,$features[0]);
    
    for (my $i=0; $i < $#features; $i++) {
      my $id  = $features[$i]  ->id;
      my $id2 = $features[$i+1]->id;
      
      # First case is if start of next hit is < end of previous
      if ( $features[$i]->end > $features[$i+1]->start && 
	  ($features[$i]->end - $features[$i+1]->start + 1) < $overlap) {
	
	if ($features[$i]->strand == 1) {
	  $newfeatures[$count]-> end($features[$i+1]->end);
	  $newfeatures[$count]->hend($features[$i+1]->hend);
	} 
	else {
	  $newfeatures[$count]-> end($features[$i+1]->end);
	  $newfeatures[$count]->hend($features[$i+1]->hstart);
	}
	
	# Take the max score
	if ($features[$i+1]->score > $newfeatures[$count]->score) {
	  $newfeatures[$count]->score($features[$i+1]->score);
	}
	
	if ($features[$i+1]->hstart == $features[$i+1]->hend) {
	  $features[$i+1]->strand($features[$i]->strand);
	}
	
	# Allow a small gap if < $query_gap, $homol_gap
      } elsif (($features[$i]->end < $features[$i+1]->start) &&
	       abs($features[$i+1]->start - $features[$i]->end) <= $query_gap) {
	
	if ($features[$i]->strand eq "1") {
	  $newfeatures[$count]->end($features[$i+1]->end);
	  $newfeatures[$count]->hend($features[$i+1]->hend);
	} else {
	  $newfeatures[$count]->end($features[$i+1]->end);
	  $newfeatures[$count]->hstart($features[$i+1]->hstart);
	}
	
	if ($features[$i+1]->score > $newfeatures[$count]->score) {
	  $newfeatures[$count]->score($features[$i+1]->score);
	}
	
	if ($features[$i+1]->hstart == $features[$i+1]->hend) {
	  $features[$i+1]->strand($features[$i]->strand);
	}
	
      } else {
	# we can't extend the merged homologies so start a
	# new homology feature
	
	# first do the coords on the old feature
	if ($newfeatures[$count]->hstart > $newfeatures[$count]->hend) {
	  my $tmp = $newfeatures[$count]->hstart;
	  $newfeatures[$count]->hstart($newfeatures[$count]->hend);
	  $newfeatures[$count]->hend($tmp);
	}
	
	$count++;
	$i++;
	
	push(@newfeatures,$features[$i]);
	$i--;
      }
    }
    
    # Adjust the last new feature coords
    if ($newfeatures[$#newfeatures]->hstart > $newfeatures[$#newfeatures]->hend) {
      my $tmp = $newfeatures[$#newfeatures]->hstart;
      $newfeatures[$#newfeatures]->hstart($newfeatures[$#newfeatures]->hend);
      $newfeatures[$#newfeatures]->hend($tmp);
    }
    
    my @pruned = $self->prune_features(@newfeatures);
    
    push(@mergedfeatures,@pruned);
  }
  return @mergedfeatures;
}

############################################################

=head2 prune_features

 Description: prunes out duplicated features
 Returntype : array of Bio::EnsEMBL::SeqFeature
 Args       : array of Bio::EnsEMBL::SeqFeature

=cut

sub prune_features {
  my ($self,@features)  = @_;
    
  my @pruned;

  @features = sort {$a->start <=> $b->start} @features;

  my $prev = -1;

  F: 
  foreach  my $f (@features) {
    if ($prev != -1 && $f->hseqname eq $prev->hseqname &&
	$f->start   == $prev->start &&
	$f->end     == $prev->end   &&
	$f->hstart  == $prev->hstart &&
	$f->hend    == $prev->hend   &&
	$f->strand  == $prev->strand &&
	$f->hstrand == $prev->hstrand) {
    } 
    else {
      push(@pruned,$f);
      $prev = $f;
    }
  }
  return @pruned;
}

############################################################

=head2 check_link

 Title   : check_link
 Usage   : $self->check_link($exon1, $exon2, $feature1, $feature2)
 Function: checks to see whether the 2 exons can be linked by the 2 features
 Returns : 1 if exons can be linked, otherwise 0
 Args    : two Bio::EnsEMBL::Exon, two Bio::EnsEMBL::FeaturePair

=cut

sub check_link {
    my ($self,$exon1,$exon2,$f1,$f2) = @_;

    my @pairs = $self->get_all_ExonPairs;
#    print STDERR "Checking link for " . $f1->hseqname . " " . $f1->hstart . " " . $f1->hend . " " . $f2->hstart . " " . $f2->hend . "\n";

    # are these 2 exons already linked in this pair?
    foreach my $pair (@pairs) {
      
      if ($exon1->strand == 1) {
	if ($exon1 == $pair->exon1) {
	  my @linked_features = $pair->get_all_Evidence;
	  
	  foreach my $f (@linked_features) {
	    
	    if ($f->hseqname eq $f2->hseqname && $f->hstrand == $f2->hstrand) {
	      return 0;
	    }
	  }
	}
      } 
      else {
	if ($exon2 == $pair->exon2) {
	  my @linked_features = $pair->get_all_Evidence;
	  
	  foreach my $f (@linked_features) {
	    
	    if ($f->hseqname eq $f2->hseqname && $f->hstrand == $f2->hstrand) {
	      return 0;
	    }
	  }
	}
      }
      
      # if we're still here, are these 2 exons already part of a pair but linked by different evidence?
      if(($exon1 == $pair->exon1 && $exon2 == $pair->exon2) || 
	 ($exon1 == $pair->exon2 && $exon2 == $pair->exon1)){

	# add in new evidence
	$pair->add_Evidence($f1);
	$pair->add_Evidence($f2);
	
	return 0;
      }
    }
    
    # exons are not linked
    return 1;
}

############################################################

=head2 link_ExonPairs

 Title   : link_ExonPairs
 Usage   : my @transcript = $self->make_ExonPairs(@exons);
 Function: Links ExonPairs into Transcripts, validates transcripts, rejects any with < $GB_MIN_GENSCAN_EXONS exons
 Example : 
 Returns : Array of Bio::EnsEMBL::Pipeline::ExonPair
 Args    : Array of Bio::EnsEMBL::Transcript

=cut

sub link_ExonPairs {
    my ($self) = @_;

    my @exons  = $self->prediction_exons;
    my @tmpexons;

  EXON: foreach my $exon (@exons) {
	$self->throw("[$exon] is not a Bio::EnsEMBL::Exon") unless $exon->isa("Bio::EnsEMBL::Exon");

	if ($self->isHead($exon) == 1) {
	    
	    # We have a higher score threshold for single exons
	    # and we need a protein hit

	    if ($self->isTail($exon)) {
		my $found = 0;
		foreach my $f (@{$exon->get_all_supporting_features}) {

# ARGHHHHH VAC hard coding

#		    if ($f->analysis->db eq "sptr" && $f->score > 200) {
		    if ($f->analysis->db eq "swall" && $f->score > 200) {
			$found = 1;
		    } 
		}
		next EXON unless ($found == 1);

	    }

	    my $transcript = new Bio::EnsEMBL::Transcript;

	    $self      ->add_Transcript($transcript);
	    $transcript->add_Exon       ($exon);

	    $self->_recurseTranscript($exon,$transcript);
	}
    }
    my $count = 1;

    foreach my $tran ($self->get_all_Transcripts) {
	$tran->{'temporary_id'} = ($TRANSCRIPT_ID_SUBSCRIPT . "." . $self->contig->id . "." .$count);
	$self->make_Translation($tran,$count);
	$count++;
    }
    
    my @t = $self->get_all_Transcripts;

    # validate the transcripts
    # flush transcripts & re-add valid ones.
    $self->flush_Transcripts;
    foreach my $transcript(@t){
      my @valid = $self->validate_transcript($transcript);
      foreach my $vt(@valid){
	@tmpexons = @{$vt->get_all_Exons};
	if(scalar (@tmpexons) >= $GB_MIN_GENSCAN_EXONS){
	  $self->add_Transcript($vt);
	}
      }
    }
    return $self->get_all_Transcripts;
}

############################################################


=head2 _recurseTranscript

 Title   : _recurseTranscript
 Usage   : $self->_recurseTranscript($exon,$transcript)
 Function: Follows ExonPairs to form a new transcript
 Example : 
 Returns : nothing
 Args    : Bio::EnsEMBL::Exon Bio::EnsEMBL::Transcript

=cut
  
  
sub _recurseTranscript {
  my ($self,$exon,$tran) = @_;
  if (defined($exon) && defined($tran)) {
    $self->throw("[$exon] is not a Bio::EnsEMBL::Exon")       unless $exon->isa("Bio::EnsEMBL::Exon");
    $self->throw("[$tran] is not a Bio::EnsEMBL::Transcript") unless $tran->isa("Bio::EnsEMBL::Transcript");
  } else {
    $self->throw("Wrong number of arguments [$exon][$tran] to _recurseTranscript");
  }
  
  # Checks for circular genes here.
  my %exonhash;
  
  foreach my $exon (@{$tran->get_all_Exons}) {
    $exonhash{$exon->{'temporary_id'}}++;
  }
  
  foreach my $exon (keys %exonhash) {
    if ($exonhash{$exon} > 1) {
      $self->warn("Eeeek! Found exon " . $exon . " more than once in the same gene. Bailing out");
      
      $tran = undef;
      
      return;
    }
  }
  
  # First copy all the exons into a new gene
  my $tmptran = new Bio::EnsEMBL::Transcript;
  
  foreach my $ex (@{$tran->get_all_Exons}) {
    $tmptran->add_Exon($ex);
  }
  
  my $count = 0;
  
  my @pairs = $self->_getPairs($exon);
  
  #    print STDERR "Pairs are @pairs\n";
  
  my @exons = @{$tran->get_all_Exons};
  
  if ($exons[0]->strand == 1) {
    @exons = sort {$a->start <=> $b->start} @exons;
    
  } 
  else {
    @exons = sort {$b->start <=> $a->start} @exons;
  }
  
  
 PAIR: foreach my $pair (@pairs) {
    #	print STDERR "Comparing " . $exons[$#exons]->{'temporary_id'} . "\t" . $exons[$#exons]->end_phase . "\t" . 
    #	    $pair->exon2->{'temporary_id'} . "\t" . $pair->exon2->phase . "\n";
    next PAIR if ($exons[$#exons]->end_phase != $pair->exon2->phase);
    
    $self->{'_usedPairs'}{$pair} = 1;
    
    if ($count > 0) {
      my $newtran = new Bio::EnsEMBL::Transcript;
      $self->add_Transcript($newtran);
      
      foreach my $tmpex (@{$tmptran->get_all_Exons}) {
	$newtran->add_Exon($tmpex);
      }
      
      $newtran->add_Exon($pair->exon2);
      $self->_recurseTranscript($pair->exon2,$newtran);
    } else {
      $tran->add_Exon($pair->exon2);
      $self->_recurseTranscript($pair->exon2,$tran);
    }
    $count++;
  }
}

############################################################

=head2 add_Transcript

 Title   : add_Transcript
 Usage   : $self->add_Transcript
 Function:  
 Example : 
 Returns : nothing
 Args    : Bio::EnsEMBL::Transcript

=cut

sub add_Transcript {
    my ($self,$transcript) = @_;

    $self->throw("No transcript input") unless defined($transcript);
    $self->throw("Input must be Bio::EnsEMBL::Transcript") unless $transcript->isa("Bio::EnsEMBL::Transcript");

    if (!defined($self->{'_transcripts'})) {
	$self->{'_transcripts'} = [];
    }

    push(@{$self->{'_transcripts'}},$transcript);
}


############################################################

=head2 get_all_Transcripts

 Title   : get_all_Transcripts
 Usage   : my @tran = $self->get_all_Transcripts
 Function:  
 Example : 
 Returns : @Bio::EnsEMBL::Transcript
 Args    : none

=cut

sub get_all_Transcripts {
    my ($self) = @_;

    if (!defined($self->{'_transcripts'})) {
	$self->{'_transcripts'} = [];
    }

    return (@{$self->{'_transcripts'}});
}

############################################################

=head2 _getPairs

 Title   : _getPairs
 Usage   : my @pairs = $self->_getPairs($exon)
 Function: Returns an array of all the ExonPairs 
           in which this exon is exon1
 Example : 
 Returns : @Bio::EnsEMBL::Pipeline::ExonPair
 Args    : Bio::EnsEMBL::Exon

=cut

sub _getPairs {
  my ($self,$exon) = @_;
  
  my $minimum_coverage = 1;
  my @pairs;
  
  $self->throw("No exon input") unless defined($exon);
  $self->throw("Input must be Bio::EnsEMBL::Exon") unless $exon->isa("Bio::EnsEMBL::Exon");
  
  foreach my $pair ($self->get_all_ExonPairs) {
    #        print STDERR "Pairs " . $pair->exon1->{'temporary_id'} . "\t" . $pair->is_Covered . "\n";
    #        print STDERR "Pairs " . $pair->exon2->{'temporary_id'} . "\t" . $pair->is_Covered . "\n\n";
    if (($pair->exon1->{'temporary_id'} eq $exon->{'temporary_id'}) && ($pair->is_Covered == 1)) {
      push(@pairs,$pair);
    }
  }
  
  @pairs = sort { $a->exon2->start <=> $b->exon2->start} @pairs;
  return @pairs;
}

############################################################	
	
=head2 isHead

 Title   : isHead
 Usage   : my $foundhead = $self->isHead($exon)
 Function: checks through all ExonPairs to see whether this
           exon is connected to a preceding exon.
 Example : 
 Returns : 0,1
 Args    : Bio::EnsEMBL::Exon

=cut


sub isHead {
    my ($self,$exon) = @_;

    my $minimum_coverage = 1;

    foreach my $pair ($self->get_all_ExonPairs) {

	my $exon2 = $pair->exon2;
	if (($exon->{'temporary_id'}  eq $exon2->{'temporary_id'}) && ($pair->is_Covered == 1)) {
	    return 0;
	}
    }

    return 1;
}

############################################################

=head2 isTail

 Title   : isTail
 Usage   : my $foundtail = $self->isTail($exon)
 Function: checks through all ExonPairs to see whether this
           exon is connected to a following exon.
 Example : 
 Returns : 0,1
 Args    : Bio::EnsEMBL::Exon

=cut

sub isTail {
    my ($self,$exon) = @_;

    my $minimum_coverage = 1;

    foreach my $pair ($self->get_all_ExonPairs) {
	my $exon1 = $pair->exon1;

	if ($exon == $exon1 && $pair->is_Covered == 1) {
	    return 0;
	}
    }
    
    return 1;
}


############################################################
=head2 make_id_hash

 Title   : make_id_hash
 Usage   : $self->make_id_hash(@feats);
 Function: creates an hash of features hashed on hseqname 
 Returns : hash
 Args    : array of Bio::EnsEMBL::FeaturePair objects

=cut

sub make_id_hash {
    my ($self,@features) = @_;

    my %id;

    foreach my $f (@features) {
	if (!defined($id{$f->hseqname})) {
	    $id{$f->hseqname} = [];
	}
	push(@{$id{$f->hseqname}},$f);
    }

    return \%id;
}

############################################################

=head2 make_Translation

 Title   : make_Translation
 Usage   : $self->make_Translation($transcript,$count)
 Function: builds a translation for a Transcript object
 Returns : Bio::EnsEMBL::Translation
 Args    : $transcript - Bio::EnsEMBL::Transcript object
           $count - translation count?

=cut

sub make_Translation{
    my ($self,$transcript,$count) = @_;

    my $translation = new Bio::EnsEMBL::Translation;

    my @exons = @{$transcript->get_all_Exons};
    my $exon  = $exons[0];


    $translation->{'temporary_id'} = ("TMPP_" . $exon->contig_id . "." . $count);
 
    if ($exon->phase != 0) {
	my $tmpphase = $exon->phase;
	
	print("Starting phase is not 0 " . $tmpphase . "\t" . $exon->strand ."\n");
	
	if ($exon->strand == 1) {
	  my $tmpstart = $exon->start;
	  $exon->start($tmpstart + 3 - $tmpphase);
	  $exon->phase(0);
	} else {
	  my $tmpend= $exon->end;
	  $exon->end($tmpend - 3 + $tmpphase);
#	  print ("New start end " . $exon->start . "\t" . $exon->end . "\n");
	  $exon->phase(0);
	}
#	print ("New coords are " . $exon-> start . "\t" . $exon->end . "\t" . $exon->phase . "\t" . $exon->end_phase . "\n");
    }   

#    print ("Transcript strand is " . $exons[0]->strand . "\n");
    
    if ($exons[0]->strand == 1) {
      @exons = sort {$a->start <=> $b->start} @exons;
    } else {
      @exons = sort {$b->start <=> $a->start} @exons;
#      print("Start exon is " . $exons[0]->{'temporary_id'} . "\n");
    }
 
    if( $exons[0]->phase == 0 ) {
      $translation->start(1);
    } elsif ( $exons[0]->phase == 1 ) {
      $translation->start(3);
    } elsif ( $exons[0]->phase == 2 ) {
      $translation->start(2);
    } else {
      $self->throw("Nasty exon phase".$exons[0]->phase);
    }
    
    $translation->start_exon($exons[0]);
    $translation->end_exon  ($exons[$#exons]);

    $translation->end($exons[$#exons]->end - $exons[$#exons]->start + 1);

    $translation->start_exon($exons[0]);
    $translation->end_exon  ($exons[$#exons]);
    
    $transcript->translation($translation);
}   


############################################################

sub check_ExonPair {
    my ($self,$pair) = @_;

    my $exon1  = $pair->exon1;
    my $exon2  = $pair->exon2;

    my $frame1 = $self->each_ExonFrame($exon1);
    my $frame2 = $self->each_ExonFrame($exon2);

    my $trans1 = $pair->exon1->translate();
    my $trans2 = $pair->exon2->translate();

    my $splice1;
    my $splice2;

    my $spliceseq;

    if ($pair->exon1->strand == 1) {
	$splice1 = $exon1->{'_gsf_seq'}->subseq($exon1->end+1,$exon1->end+2);
	$splice2 = $exon2->{'_gsf_seq'}->subseq($exon2->start-2,$exon2->start-1);
	$spliceseq = new Bio::Seq('-id' => "splice",
				  '-seq' => "$splice1$splice2");
    } else {
	$splice1 = $exon1->{'_gsf_seq'}->subseq($exon1->start-2,
						$exon1->start-1);
	$splice2 = $exon2->{'_gsf_seq'}->subseq($exon2->end+1,
						$exon2->end+2);
	$spliceseq = new Bio::Seq('-id' => "splice",
				  '-seq' => "$splice2$splice1");
	$spliceseq = $spliceseq->revcom;
    }

    $pair->splice_seq($spliceseq);

#    print (STDERR "Splice " . $spliceseq->seq ."\n");

    return 1;
    return 0 if ($spliceseq ->seq ne "GTAG");
    return 1 if ($pair->exon1->end_phase == $pair->exon2->phase);
    return 0;

    my $match  = 0;
    my $oldphase1 = $exon1->phase;
    my $oldphase2 = $exon2->phase;
    
    foreach my $frame (keys %$frame1) {
	
	$exon1->phase($frame-1);
	my $endphase = $exon1->end_phase;
#	print (STDERR "Looking for exon2 phase of " . $endphase+1 . "\n");

	if ($frame2->{$endphase+1} == 1) {
#	    print STDERR "Hooray! Found matching phases\n";
	    $match = 1;
	    $exon2->phase($endphase);

	    my $trans1 = $exon1->seq->translate('*','X',(3-$exon1->phase)%3)->seq;
	    my $trans2 = $exon2->seq->translate('*','X',(3-$exon2->phase)%3)->seq;

#	    print(STDERR "exon 1 " . $exon1->{'temporary_id'} . " translation $frame : " . $trans1. "\n");
#	    print(STDERR "exon 2 " . $exon2->{'temporary_id'} . " translation " . ($endphase+1) . " : " . $trans2. "\n");

	    if ($self->add_ExonPhase($exon1) && $self->add_ExonPhase($exon2)) {
		return $match;
	    } else {
		$exon1->phase($oldphase1);
		$exon2->phase($oldphase2);
	    }
	} else {
	    $exon1->phase($oldphase1);
	}
    }
    return $match;
}

############################################################

sub each_ExonFrame {
    my ($self,$exon) = @_;

    return $self->{'_framehash'}{$exon};
}

############################################################

sub add_ExonPhase {
    my ($self,$exon) = @_;

    if (defined($self->{'_exonphase'}{$exon})) {
#	print STDERR "Already defined phase : old phase " . $self->{'_exonphase'}{$exon} . " new " . $exon->phase . "\n";
	if ($self->{'_exonphase'}{$exon} != $exon->phase) {
	    return 0;
	}
    } else {
	$self->{'_exonphase'}{$exon} = $exon->phase;
	return 1;
    }


}


############################################################
#
# GETSET METHODS
#
############################################################

=head2 linked_predictions

 Description: get/set for the transcripts built from linking the exon-pairs
              taken from the prediction transcripts according to consecutive
              feature overlap
=cut

sub linked_predictions {
  my ($self,@linked_predictions) = @_;

  if ( @linked_predictions ) {
     push(@{$self->{_linked_predictions}},@linked_predictions);
  }
  return @{$self->{_linked_predictions}};
}

###################################################

# get/set method holding a reference to the db with genewise and combined genes
# this reference is set in Bio::EnsEMBL::Pipeline::RunnableDB::Gene_Builder

sub genes_db{
 my ($self,$genes_db) = @_;
 if ( $genes_db ){
   $self->{_genes_db} = $genes_db;
 }
 return $self->{_genes_db};
}

############################################################

sub genewise_combined_Transcripts {
    my ($self,@genes) = @_;

    if (!defined($self->{_genes})) {
        $self->{_genes} = [];
    }

    if (scalar @genes > 0) {
	push(@{$self->{_genes}},@genes);
    }

    return @{$self->{_genes}};
}

############################################################

sub threshold {
    my ($self,$arg) = @_;

    if (defined($arg)) {
	$self->{'_threshold'} = $arg;
    }

    return $self->{'_threshold'} || 100;
}
############################################################

sub flush_Genes {
  my ($self) = @_;

  $self->{'_genes'} = [];
}

sub flush_Transcripts {
  my ($self) = @_;

  $self->{'_transcripts'} = [];
}
############################################################

sub add_Gene {
    my ($self,$gene) = @_;

    if (!defined($self->{'_genes'})) {
	$self->{'_genes'} = [];
    }
    push(@{$self->{'_genes'}},$gene);
}

sub each_Gene {
    my ($self) = @_;

    if (!defined($self->{'_genes'})) {
	$self->{'_genes'} = [];
    }

    return (@{$self->{'_genes'}});
}
############################################################

=head2 gene_types

 Description: get/set for the type(s) of genewise/combined genes to be used in the genebuilder
              they get set in new()

=cut

sub gene_types {
  my ($self,$type) = @_;

  if (defined($type)) {
     push(@{$self->{_gene_types}},$type);
  }

  return @{$self->{_gene_types}};
}
############################################################

=head2 predictions

 Description: get/set for the PredictionTranscripts
                         they get set in new()

=cut

sub predictions {
  my ($self,@predictions) = @_;

  if ( @predictions ) {
     push(@{$self->{_predictions}},@predictions);
  }
  return @{$self->{_predictions}};
}

############################################################

sub features {
  my ($self,@features) = @_;
  
  if (!defined($self->{_feature})) {
    $self->{_feature} = [];
  }
  if ( scalar @features ) {
    push(@{$self->{_feature}},@features);
  }
  return @{$self->{_feature}};
}

############################################################


sub prediction_exons {
    my ($self,@exons) = @_;

    if (!defined($self->{'_prediction_exons'})) {
	$self->{'_prediction_exons'} = [];
    }
    if (scalar @exons > 0) {
	push(@{$self->{'_prediction_exons'}},@exons);
    }
    return @{$self->{'_prediction_exons'}};
}

############################################################

sub slice {
    my ($self,$slice) = @_;
    
    if (defined($slice)) {
      $self->{_slice} = $slice;
    }
    return $self->{_slice};
}

############################################################

sub _make_Exon { 
    my ($self,$subf,$stub) = @_;

    my $sliceid = $self->slice->id;
    my $exon     = new Bio::EnsEMBL::Exon;

    $exon->{'temporary_id'} = ("TMPE_" . $sliceid . "." . $subf->id . "." . $stub);
    $exon->seqname   ($exon->{'temporary_id'});
    $exon->contig    ($self->slice);
    $exon->start     ($subf->start);
    $exon->end       ($subf->end  );
    $exon->strand    ($subf->strand);
    $exon->phase     ($subf->phase);
    $exon->attach_seq($self->contig->primary_seq);
    $exon->add_supporting_features($subf);
    
    $exon->{'_5splice'} = $subf->{'_5splice'};
    $exon->{'_3splice'} = $subf->{'_3splice'};

    return $exon;
}

############################################################

=head2 get_all_ExonPairs

 Title   : 
 Usage   : 
 Function: 
 Example : 
 Returns : 
 Args    : 

=cut


sub get_all_ExonPairs {
    my ($self) = @_;

    if (!defined($self->{'_exon_pairs'})) {
	$self->{'_exon_pairs'} = [];
    }
    return @{$self->{'_exon_pairs'}};
}

############################################################

=head2 add_ExonPair

 Title   : add_ExonPair
 Usage   : 
 Function: 
 Example : 
 Returns : 
 Args    : 

=cut

sub add_ExonPair {
    my ($self,$arg) = @_;


    if (!defined($self->{'_exon_pairs'})) {
	$self->{'_exon_pairs'} = [];
    }

    if (defined($arg) && $arg->isa("Bio::EnsEMBL::Pipeline::ExonPair")) {
	push(@{$self->{'_exon_pairs'}},$arg);
#        print STDERR "Adding exon pair $arg\n";
    } else {
	$self->throw("[$arg] is not a Bio::EnsEMBL::Pipeline::ExonPair");
    }
}

#############################################################################
# 
# Printing routines
#
#############################################################################

sub print_Exon {
  my ($self,$exon) = @_;
  
  print STDERR $exon->seqname." ".
    $exon->start ."-".$exon->end." ".$exon->strand." [".$exon->phase.",".$exon->end_phase."]\n";
}

############################################################
  
sub _print_Transcript{
  my ($self,$transcript) = @_;
  my @exons = @{$transcript->get_all_Exons};
  my $id;
  if ( $transcript->dbID ){
    $id = $transcript->dbID;
  }
  else{
    $id = "no id";
  }
  print STDERR "transcript id: ".$id."\n";
  foreach my $exon ( @exons){
    $self->print_Exon($exon);
  }
  print STDERR "\n";
  #print STDERR "Translation : ".$transcript->translation."\n";
  print STDERR "translation start exon: ".
    $transcript->translation->start_exon->start."-".$transcript->translation->start_exon->end.
      " start: ".$transcript->translation->start."\n";
  print STDERR "translation end exon: ".
    $transcript->translation->end_exon->start."-".$transcript->translation->end_exon->end.
      " end: ".$transcript->translation->end."\n";
}

############################################################

sub print_ExonPairs {
  my ($self) = @_;
  
  foreach my $pair ($self->get_all_ExonPairs) {
    $self->print_ExonPair($pair);
  }
}

############################################################

sub print_ExonPair {
  my ($self,$pair) = @_;
  
  $self->print_Exon($pair->exon1);
  $self->print_Exon($pair->exon2);
  
  print(STDERR "\nExon Pair (splice - " . $pair->splice_seq->seq . ")\n");
  
  foreach my $ev ($pair->get_all_Evidence) {
    print(STDERR "   -  " . $ev->hseqname . "\t" . $ev->hstart . "\t" . $ev->hend . "\t" . $ev->strand . "\n");
  }
}

############################################################

sub print_Transcript {
  my ($self,$tran) = @_;

  
  print STDERR "\nTranscript - " . $tran->dbID . "\n";
  my $cdna;
  
  foreach my $exon ( @{ $tran->get_all_Exons }) {
    $cdna .= $exon->seq->seq;
  }
  
  my $seq = $tran->translate->seq;
  $seq =~ s/(.{72})/$1\n/g;
  print STDERR "\nTranslation is\n\n" . $seq . "\n";

}

############################################################


=head2 prune_gene

 Title   : prune_gene
 Usage   : my @newgenes = $self->prune_gene($gene)
 Function: rejects duplicate transcripts, transfers supporting feature data from rejected transcripts
 Returns : array of Bio::EnsEMBL::Gene
 Args    : Bio::EnsEMBL::Gene

=cut

sub prune_gene {
  my ($self, $gene) = @_;
  
  my @clusters;
  my @transcripts;
  my %lengths;
  
  my @newgenes;
  my $max_num_exons = 0;
  my @transcripts = @{ $gene->get_all_Transcripts};

  # sizehash holds transcript length - based on sum of exon lengths
  my %sizehash;

  # orfhash holds orf length - based on sum of translateable exon lengths
  my %orfhash;

  my %tran2orf;
  my %tran2length;
  
  # keeps track of to which transcript(s) this exon belong
  my %exon2transcript;
  
  foreach my $tran (@transcripts) {
    # keep track of number of exons in multiexon transcripts
    my @exons = @{ $tran->get_all_Exons };
    if(scalar(@exons) > $max_num_exons){ $max_num_exons = scalar(@exons); }

    # total exon length
    my $length = 0;
    foreach my $e ( @{ $tran->get_all_Exons} ){
      $length += $e->end - $e->start + 1;

      push ( @{ $exon2transcript{ $e } }, $tran );

    }
    $sizehash{$tran->{'temporary_id'}} = $length;
    $tran2length{ $tran } = $length;

    # now for ORF length
    $length = 0;
    foreach my $e($tran->translateable_exons){
      $length += $e->end - $e->start + 1;
    }
    $tran2orf{ $tran } = $length;
    push(@{$orfhash{$length}}, $tran);
  }

  # VAC 15/02/2002 sort transcripts based on total exon length - this
  # introduces a problem - we can (and have) masked good transcripts
  # with long translations in favour of transcripts with shorter
  # translations and long UTRs that are overall slightly longer. This
  # is not good.

# better way? hold both total exon length and length of translateable exons. Then sort:
# long translation + UTR > long translation no UTR > short translation + UTR > short translation no UTR

  
  # eae: Notice that this sorting:
  my @sordid_transcripts =  sort { my $result = ( 
						 $tran2orf{ $b }
						 <=> 
						 $tran2orf{ $a }
						);
				   if ($result){
				     return $result;
				   }
				   else{
				     return ( $tran2length{ $b } <=> $tran2length{ $a } )
				   }
				 } @transcripts;

  # is only equivalent to the one used below when all transcripts have UTRs. 
  # The one below is actually the desired behaviour.
  # since we want long UTRs and long ORFs but the sorting must be fuzzy in the sense that we want to give priority 
  # to a long ORF with UTR over a long ORF without UTR which could only slightly longer.

  #test
  #print STDERR "1.- sordid transcripts:\n";
  #foreach my $tran (@sordid_transcripts){
  #  print STDERR $tran." orf_length: $tran2orf{$tran}, total_length: $tran2length{$tran}\n";
  #}
  
  @transcripts = ();
  # sort first by orfhash{'length'}
  my @orflengths = sort {$b <=> $a} (keys %orfhash);
  
  # strict sort by translation length is just as wrong as strict sort by UTR length
  # bin translation lengths - 4 bins (based on 25% length diff)? 10 bins (based on 10%)?
  my %orflength_bin;
  my $numbins = 4;
  my $currbin = 1;

  foreach my $orflength(@orflengths){
    last if $currbin > $numbins;
    my $percid = ($orflength*100)/$orflengths[0];
    if ($percid > 100) { $percid = 100; }
    my $currthreshold = $currbin * (100/$numbins);
    $currthreshold = 100 - $currthreshold;

    if($percid <$currthreshold) { $currbin++; }
    my @tmp = @{$orfhash{$orflength}};
    push(@{$orflength_bin{$currbin}}, @{$orfhash{$orflength}});
  }

  # now, foreach bin in %orflengthbin, sort by exonlength
  $currbin = 1;
  EXONLENGTH_SORT:
  while( $currbin <= $numbins){
    if(!defined $orflength_bin{$currbin} ){
      $currbin++;
      next EXONLENGTH_SORT;
    }

    my @sorted_transcripts = sort {$sizehash{$b->{'temporary_id'}} <=> $sizehash{$a->{'temporary_id'}}} @{$orflength_bin{$currbin}};
    push(@transcripts, @sorted_transcripts);
    $currbin++;
  }

  #test
  print STDERR "2.- sorted transcripts:\n";
  foreach my $tran (@transcripts){
    if ( $tran->dbID ){
      print STDERR $tran->dbID." ";
    }
    print STDERR "orf_length: $tran2orf{$tran}, total_length: $tran2length{$tran}\n";
    my @exons = @{$tran->get_all_Exons};
    if ( $exons[0]->strand == 1 ){
      @exons = sort { $a->start <=> $b->start } @exons;
    }
    else{
      @exons = sort { $b->start <=> $a->start } @exons;
    }
    foreach my $exon ( @{$tran->get_all_Exons} ){
      print "  ".$exon->start."-".$exon->end." ".( $exon->end - $exon->start + 1)." phase: ".$exon->phase." end_phase ".$exon->end_phase." strand: ".$exon->strand."\n";
    }
  }
  
# old way - sort strictly on exon length
#    @transcripts = sort {$sizehash{$b->{'temporary_id'}} <=> $sizehash{$a->{'temporary_id'}}} @transcripts;

  # deal with single exon genes
  my @maxexon = @{$transcripts[0]->get_all_Exons};
  # do we really just want to take the first transcript only? What about supporting evidence from other transcripts?
  # also, if there's a very long single exon gene we will lose any underlying multi-exon transcripts
  #  if ($#maxexon == 0) {

  # this may increase problems with the loss of valid single exon genes as mentioned below. 
  # it's a balance between keeping multi exon transcripts and losing single exon ones
  if ($#maxexon == 0 && $max_num_exons == 1) {
    my $gene = new Bio::EnsEMBL::Gene;
    $gene->type('pruned');
    $gene->{'temporary_id'} = ($transcripts[0]->{'temporary_id'});
    push(@newgenes,$gene);
    
    $gene->type('pruned');
    $gene->add_Transcript($transcripts[0]);

    # we are done
    return @newgenes;
  }


  # otherwise we need to deal with multi exon transcripts and reject duplicates.

  # links each exon in the transcripts of this cluster with a hash of other exons it is paired with
  my %pairhash;
  
  # allows retrieval of exon objects by exon->id - convenience
  my %exonhash;
  my @newtran;
  
  foreach my $tran (@transcripts) {
    my @exons = @{$tran->get_all_Exons};
    $tran->sort;

    #print STDERR "\ntranscript: ".$tran->{'temporary_id'}."\n";
    #foreach my $exon ( @exons ){
    #  print STDERR $exon->start."-".$exon->end." ";
    #}
    #print STDERR "\n";

    
    my $i     = 0;
    my $found = 1;
    
    # if this transcript has already been seen, this
    # will be used to transfer supporting evidence
    my @evidence_pairs;

# 10.1.2002 VAC we know there's a potential problem here - single exon transcripts which are in a 
# cluster where the longest transcriopt has > 1 exon are not going to be considered in 
# this loop, so they'll always be marked "transcript already seen"
# How to sort them out? If the single exon overlaps an exon in a multi exon transcript then 
# by our rules it probably ought to be rejected the same way transcripts with shared exon-pairs are.
# Tough one.
# more of a problem is that if the transcript with the largest number of exons is really a
# single exon with frameshifts, it will get rejected here based on intron size but in addition
# any valid non-frameshifted single exon transcripts will get rejected - which is definitely not right.
# We need code to represent frameshifted exons more sensibly so the frameshifted one doesn't 
# get through the check for single exon genes above.


  EXONS:
    for ($i = 0; $i < $#exons; $i++) {
      my $foundpair = 0;
      my $exon1 = $exons[$i];
      my $exon2 = $exons[$i+1];
 
      # Only count introns > 50 bp as real introns
      my $intron;
      if ($exon1->strand == 1) {
	$intron = abs($exon2->start - $exon1->end - 1);
      } else {
	$intron = abs($exon1->start - $exon2->end - 1);
      }
      
      #	print STDERR "Intron size $intron\n";
      if ($intron < 50) {
	$foundpair = 1; # this pair will not be compared with other transcripts
      } 
      else {
	
	# go through the exon pairs already stored in %pairhash. 
	# If there is a pair whose exon1 overlaps this exon1, and 
	# whose exon2 overlaps this exon2, then these two transcripts are paired
	
	foreach my $exon1id (keys %pairhash) {
	  my $exon1a = $exonhash{$exon1id};
	  
	  foreach my $exon2id (keys %{$pairhash{$exon1id}}) {
	    my $exon2a = $exonhash{$exon2id};
	    
	    if (($exon1->overlaps($exon1a) && $exon2->overlaps($exon2a))) {
	      $foundpair = 1;
	      
	      # eae: this method allows a transcript to be covered by exon pairs
	      # from different transcripts, rejecting possible
	      # splicing variants

	      # we put first the exon from the transcript being tested:
	      push( @evidence_pairs, [ $exon1 , $exon1a ] );
	      push( @evidence_pairs, [ $exon2 , $exon2a ] );
	      
	      # transfer evidence between exons, assuming the suppfeat coordinates are OK.
	      # currently not working as the supporting evidence is not there - 
	      # can get it for genewsies, but why not there for genscans?
	      #	      $self->transfer_supporting_evidence($exon1, $exon1a);
	      #	      $self->transfer_supporting_evidence($exon1a, $exon1);
	      #	      $self->transfer_supporting_evidence($exon2, $exon2a);
	      #	      $self->transfer_supporting_evidence($exon2a, $exon2);
	    }
	  }
	}
      }
      
      if ($foundpair == 0) { # ie this exon pair does not overlap with a pair yet found in another transcript
	
	#		    	    print STDERR "Found new pair\n";
	$found = 0; # ie currently this transcript is not paired with another
	
	# store the exons so they can be retrieved by id
	$exonhash{$exon1->{'temporary_id'}} = $exon1;
	$exonhash{$exon2->{'temporary_id'}} = $exon2;
	
	# store the pairing between these 2 exons
	$pairhash{$exon1->{'temporary_id'}}{$exon2->{'temporary_id'}} = 1;
      }
    }   # end of EXONS
    
    # decide whether this is a new transcript or whether it has already been seen
    if ($found == 0) {
      #print STDERR "found new transcript " . $tran->{'temporary_id'} . "\n";
      push(@newtran,$tran);
      @evidence_pairs = ();
    } 
    else {
      #print STDERR "\n\nTranscript already seen " . $tran->{'temporary_id'} . "\n";
      
      ## transfer supporting feature data. We transfer it to exons
      foreach my $pair ( @evidence_pairs ){
	my @pair = @$pair;
	
	# first in the pair is the 'already seen' exon
	my $source_exon = $pair[0];
	my $target_exon = $pair[1];
	
	
      
	#print STDERR "\n";
	$self->transfer_supporting_evidence($source_exon, $target_exon)
      }
    }
  } # end of this transcript
  
  # make new transcripts into genes
  if ($#newtran >= 0) {
    my $gene = new Bio::EnsEMBL::Gene;
    $gene->type('pruned');
    
    my $count = 0;
    foreach my $newtran (@newtran) {
      $gene->{'temporary_id'} = ("TMPG_" . $newtran->{'temporary_id'});
      # hardcoded limit to prevent mad genes with lots of transcripts
      if ($count < 10) {
	$gene->add_Transcript($newtran);
      }
      $count++;
    }
    
    push(@newgenes,$gene);
  }


  
  return @newgenes;  
}

############################################################

=head2 split_transcript

 Title   : split_transcript 
 Usage   : my @splits = $self->split_transcript($transcript)
 Function: splits a transcript into multiple transcripts at long introns. Rejects single exon 
           transcripts that result. 
 Returns : @Bio::EnsEMBL::Transcript
 Args    : Bio::EnsEMBL::Transcript

=cut


sub split_transcript{
  my ($self, $transcript) = @_;
  $transcript->sort;
  my @split_transcripts   = ();

  if(!($transcript->isa("Bio::EnsEMBL::Transcript"))){
    $self->warn("[$transcript] is not a Bio::EnsEMBL::Transcript - cannot split");
    return (); # empty array
  }
  
  my $prev_exon;
  my $exon_added = 0;
  my $curr_transcript = new Bio::EnsEMBL::Transcript;
  my $translation     = new Bio::EnsEMBL::Translation;
  $curr_transcript->translation($translation);


EXON:   
  foreach my $exon( @{$transcript->get_all_Exons} ){
    
    $exon_added = 0;
      # is this the very first exon?
    if($exon == $transcript->start_exon){


      $prev_exon = $exon;
      
      # set $curr_transcript->translation start and start_exon
      $curr_transcript->add_Exon($exon);
      $exon_added = 1;
      $curr_transcript->translation->start_exon($exon);
      $curr_transcript->translation->start($transcript->translation->start);
      push(@split_transcripts, $curr_transcript);
      next EXON;
    }
    
    if ($exon->strand != $prev_exon->strand){
      return (); # empty array
    }

    # We need to start a new transcript if the intron size between $exon and $prev_exon is too large
    my $intron = 0;
    if ($exon->strand == 1) {
      $intron = abs($exon->start - $prev_exon->end + 1);
    } else {
      $intron = abs($exon->end   - $prev_exon->start + 1);
    }
    
    if ($intron > $GB_GENSCAN_MAX_INTRON) {
      $curr_transcript->translation->end_exon($prev_exon);
      # need to account for end_phase of $prev_exon when setting translation->end
      $curr_transcript->translation->end($prev_exon->end - $prev_exon->start + 1 - $prev_exon->end_phase);
      
      # start a new transcript 
      my $t  = new Bio::EnsEMBL::Transcript;
      my $tr = new Bio::EnsEMBL::Translation;
      $t->translation($tr);

      # add exon unless already added, and set translation start and start_exon
      $t->add_Exon($exon) unless $exon_added;
      $exon_added = 1;

      $t->translation->start_exon($exon);

      if ($exon->phase == 0) {
	$t->translation->start(1);
      } elsif ($exon->phase == 1) {
	$t->translation->start(3);
      } elsif ($exon->phase == 2) {
	$t->translation->start(2);
      }

      # start exon always has phase 0
      $exon->phase(0);      

      # this new transcript becomes the current transcript
      $curr_transcript = $t;

      push(@split_transcripts, $curr_transcript);
    }

    if($exon == $transcript->end_exon){
      # add it unless already added
      $curr_transcript->add_Exon($exon) unless $exon_added;
      $exon_added = 1;

      # set $curr_transcript end_exon and end
      $curr_transcript->translation->end_exon($exon);
      $curr_transcript->translation->end($transcript->translation->end);
    }

    else{
      # just add the exon
      $curr_transcript->add_Exon($exon) unless $exon_added;
    }
    
    # this exon becomes $prev_exon for the next one
    $prev_exon = $exon;

  }

  # discard any single exon transcripts
  my @t = ();
  my $count = 1;
  
  foreach my $st(@split_transcripts){
    $st->sort;
    my @ex = @{$st->get_all_Exons};
    if(scalar(@ex) > 1){
      $st->{'temporary_id'} = $transcript->dbID . "." . $count;
      $count++;
      push(@t, $st);
    }
  }

  return @t;

}

############################################################

=head2 validate_transcript

 Title   : validate_transcript 
 Usage   : my @valid = $self->validate_transcript($transcript)
 Function: Validates a transcript - rejects if mixed strands, splits if long introns
 Returns : @Bio::EnsEMBL::Transcript
 Args    : Bio::EnsEMBL::Transcript

=cut

sub validate_transcript{
  my ($self, $transcript) = @_;
  my @valid_transcripts;

  my $valid = 1;
  my $split = 0;

  # check exon phases:
  my @exons = @{$transcript->get_all_Exons};
  $transcript->sort;
  for (my $i=0; $i<(scalar(@exons-1)); $i++){
    my $end_phase = $exons[$i]->end_phase;
    my $phase    = $exons[$i+1]->phase;
    if ( $phase != $end_phase ){
      $self->warn("rejecting transcript with inconsistent phases( $phase <-> $end_phase) ");
      return undef;
    }
  }
  

  my $previous_exon;
  foreach my $exon (@exons){
    if (defined($previous_exon)) {
      my $intron;
      
      if ($exon->strand == 1) {
	$intron = abs($exon->start - $previous_exon->end + 1);
      } else {
	$intron = abs($exon->end   - $previous_exon->start + 1);
      }
      
      if ($intron > $GB_GENSCAN_MAX_INTRON) {
	print STDERR "Intron too long $intron  for transcript " . $transcript->{'temporary_id'} . "\n";
	$split = 1;
	$valid = 0;
      }
      
      if ($exon->strand != $previous_exon->strand) {
	print STDERR "Mixed strands for gene " . $transcript->{'temporary_id'} . "\n";
	$valid = 0;
	return;
      }
    }
    $previous_exon = $exon;
  }
  
       if ($valid) {
	 push(@valid_transcripts,$transcript);
       }
       elsif ($split){
	 # split the transcript up.
	 my @split_transcripts = $self->split_transcript($transcript);
    push(@valid_transcripts, @split_transcripts);
  }
       return @valid_transcripts;
}

############################################################

=head2 transfer_supporting_evidence

 Title   : transfer_supporting_evidence
 Usage   : $self->transfer_supporting_evidence($source_exon, $target_exon)
 Function: Transfers supporting evidence from source_exon to target_exon, 
           after checking the coordinates are sane and that the evidence is not already in place.
 Returns : nothing, but $target_exon has additional supporting evidence

=cut

sub transfer_supporting_evidence{
  my ($self, $source_exon, $target_exon) = @_;
  
  my @target_sf = @{$target_exon->get_all_supporting_features};
  #  print "target exon sf: \n";
  #  foreach my $tsf(@target_sf){ print STDERR $tsf; $self->print_FeaturePair($tsf); }
  
  #  print "source exon: \n";
 
  # keep track of features already transferred, so that we do not duplicate
  my %unique_evidence;
  my %hold_evidence;

 SOURCE_FEAT:
  foreach my $feat ( @{$source_exon->get_all_supporting_features}){
    next SOURCE_FEAT unless $feat->isa("Bio::EnsEMBL::FeaturePair");
    
    # skip duplicated evidence objects
    next SOURCE_FEAT if ( $unique_evidence{ $feat } );
    
    # skip duplicated evidence 
    if ( $hold_evidence{ $feat->hseqname }{ $feat->start }{ $feat->end }{ $feat->hstart }{ $feat->hend } ){
      #print STDERR "Skipping duplicated evidence\n";
      next SOURCE_FEAT;
    }

    #$self->print_FeaturePair($feat);
    
  TARGET_FEAT:
    foreach my $tsf (@target_sf){
      next TARGET_FEAT unless $tsf->isa("Bio::EnsEMBL::FeaturePair");
      
      if($feat->start    == $tsf->start &&
	 $feat->end      == $tsf->end &&
	 $feat->strand   == $tsf->strand &&
	 $feat->hseqname eq $tsf->hseqname &&
	 $feat->hstart   == $tsf->hstart &&
	 $feat->hend     == $tsf->hend){
	
	#print STDERR "feature already in target exon\n";
	next SOURCE_FEAT;
      }
    }
    #print STDERR "from ".$source_exon->{'temporary_id'}." to ".$target_exon->{'temporary_id'}."\n";
    #$self->print_FeaturePair($feat);
    $target_exon->add_supporting_features($feat);
    $unique_evidence{ $feat } = 1;
    $hold_evidence{ $feat->hseqname }{ $feat->start }{ $feat->end }{ $feat->hstart }{ $feat->hend } = 1;
  }
}

############################################################

sub print_FeaturePair{
  my ($self, $fp) = @_;
  return unless $fp->isa("Bio::EnsEMBL::FeaturePair");
  print STDERR $fp;
  print STDERR $fp->seqname . " " .
    $fp->start . " " .
      $fp->end . " " .
	$fp->strand . " " .
	  $fp->hseqname . " " .
	    $fp->hstart . " " .
	      $fp->hend . "\n";
}

############################################################

sub _check_Transcript{
  my ($self,$transcript) = @_;
  
  my $id = $self->transcript_id( $transcript );

  my $valid = 1;

  # sort the exons 
  $transcript->sort;
  my @exons = @{$transcript->get_all_Exons};
  
  for (my $i = 1; $i <= $#exons; $i++) {
    
    $self->warn("no contig id\n") unless defined $exons[$i-1]->contig_id;
   
    
    
    


    # check phase consistency:
    if ( $exons[$i-1]->end_phase != $exons[$i]->phase  ){
      print STDERR "transcript $id has phase inconsistency\n";
      $self->_print_Transcript($transcript);
      $valid = 0;
    }
    
    # check contig consistency
    if ( !( $exons[$i-1]->seqname eq $exons[$i]->seqname ) ){
      print STDERR "transcript $id is partly outside the contig\n";
      $valid = 0;
    }
  }

  # check that they have a translation
  my $translation = $transcript->translation;
  my $sequence;
  eval{
    $sequence = $transcript->translate;
  };
  unless ( $sequence ){
    print STDERR "transcript $id has no translation\n";
    return 0;
  }
  if ( $sequence ){
    my $peptide = $sequence->seq;
    if ( $peptide =~ /\*/ ){
      print STDERR "translation of transcript $id has STOP codons\n";
      $valid = 0;
    }
  }
  if ($valid == 0 ){
    $self->_print_Transcript($transcript);
  }
  return $valid;
}


############################################################


sub transcript_id {
  my ( $self, $t ) = @_;
  my $id;
  if ( $t->stable_id ){
    $id = $t->stable_id;
  }
  elsif( $t->dbID ){
    $id = $t->dbID;
  }
  elsif( $t->temporary_id ){
    $id = $t->temporary_id;
  }
  else{
    $id = 'no-id';
  }
  return $id;
}

############################################################

1;
