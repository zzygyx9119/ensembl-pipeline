package Bio::EnsEMBL::Pipeline::GeneDuplication::Finder;

use vars qw(@ISA);
use strict;
use Bio::EnsEMBL::Root;
use Bio::Tools::Run::Alignment::Clustalw;
use Bio::EnsEMBL::Pipeline::Runnable::BlastDB;
use Bio::EnsEMBL::Pipeline::Runnable::MinimalBlast;
use Bio::EnsEMBL::Pipeline::SeqFetcher::FetchFromBlastDB;
use Bio::EnsEMBL::Pipeline::GeneDuplication::PAML;
use Bio::EnsEMBL::Pipeline::GeneDuplication::CodonBasedAlignment;
use Bio::EnsEMBL::Pipeline::GeneDuplication::Result;


my $DEFAULT_DISTANCE_METHOD  = 'NeiGojobori';
my $DEFAULT_BLAST_PROGRAM    = 'wublastn';
my $DEFAULT_DISTANCE_CUTOFF  = 1.000;

@ISA = qw(Bio::EnsEMBL::Root);

### Constructor ###

=head2 new

  Args       : -dbfile       - (string) Full path to a fasta formatted file of 
                               nucleotide sequences.
               -blastdb      - A Bio::EnsEMBL::Pipeline::Runnable::BlastDB 
                               object for which the run method has been invoked.
               -query_seq    - A Bio::Seq which is comprised of nucleotides.
               -blast_program           - Manually set the blast program (and
                               full path) that should be used.  Make sure the
                               program matches the index type chosen.  Defaults
                               to wublastn.
               -blast_index_type        - The distribution of blast to use.  See 
                               Bio::EnsEMBL::Pipeline::Runnable::BlastDB->index_type
                               documentation.  Defaults to 'wu_new'.
               -hit_identity - (optional) Hit identity.  Defaults to 0.80
               -hit_coverage - (optional) Hit coverage.  Defults to 0.80
               -work_dir     - (optional) Dir where working files are 
                                          placed.  Defaults to /tmp.
               -codeml       - Full path to codeml executable.
               -genetic_code - 0 for Universal, 1 for Mitochondrial.  See
                               the Bio::Seq->translate method for a full 
                               list of options.
               -regex_query_species     - A regular expression that will parse
                               some portion of the ids of the query species (and
			       not the ids of outgroup species).  Eg. 'ENSG'.
               -regex_outgroup_species  - A ref to an array of regular expressions
                               that will parse the ids of the various outgroup 
                               species (but not the ids of the query species).
                               E.g. ['ENSMUSG', 'ENSRNOG']
               -distance_cutoff         - A genetic distance cutoff to apply for
                               occasions where an outgroup species is not set, or
                               an outgroup species match was not found.
               -distance_method         - The method used to calculate the genetic
                               distance and Ka/Ks ratios.  Options are 'NeiGojobori'
                               and 'ML', ML being the maximum likelihood method
                               of Yang.
  Example    : none
  Description: Constructs new object
  Returntype : Bio::EnsEMBL::Pipeline::GeneDuplication::Finder
  Exceptions : Throws if database file not specified or does not exist.
  Caller     : General

=cut

sub new {
  my ($class, @args) = @_;

  my $self = bless {}, $class;

  my ($query,
      $blastdb,
      $blast_program,
      $blast_index_type,
      $work_dir,
      $codeml,
      $genetic_code,
      $regex_query_species,
      $regex_outgroup_species,
      $identity_cutoff,
      $coverage_cutoff,
      $distance_cutoff,
      $distance_method) = $self->_rearrange([qw(QUERY
						BLASTDB
						BLAST_PROGRAM
						BLAST_INDEX_TYPE
						WORK_DIR
						CODEML_EXECUTABLE
						GENETIC_CODE
						REGEX_QUERY_SPECIES
						REGEX_OUTGROUP_SPECIES
						HIT_IDENTITY
						HIT_COVERAGE
						DISTANCE_CUTOFF
						DISTANCE_METHOD
					       )],@args);

  $self->_work_dir($work_dir) if $work_dir;

  if ($blastdb && $blastdb->isa("Bio::EnsEMBL::Pipeline::Runnable::BlastDB")){
    $self->_blastdb($blastdb);
  } else {
    $self->throw("Need a Bio::EnsEMBL::Pipeline::Runnable::BlastDB object.");
  }

  $self->_query_seq($query)                               if $query;
  $self->_codeml($codeml)                                 if $codeml;
  $self->_genetic_code($genetic_code)                     if $genetic_code;
  $self->_regex_query_species($regex_query_species)       if $regex_query_species;
  $self->_regex_outgroup_species($regex_outgroup_species) if $regex_outgroup_species;
  $self->_identity_cutoff($identity_cutoff)               if $identity_cutoff;
  $self->_coverage_cutoff($coverage_cutoff)               if $coverage_cutoff;
  $self->_blast_program($blast_program)                   if $blast_program;

  $self->_identity_cutoff(80) unless $self->_identity_cutoff;
  $self->_coverage_cutoff(80) unless $self->_coverage_cutoff;

  $self->_distance_method($distance_method) if $distance_method;
  $self->_distance_cutoff($distance_cutoff) if $distance_cutoff;

  return $self
}


### Public methods ###


=head2 run

  Args[1]    : [optional] Input sequence (Bio::Seq)
  Example    : none
  Description: Top level method that executes the gene duplicate 
               finding algorithm.
  Returntype : Bio::EnsEMBL::Pipeline::GeneDuplication::Result
  Exceptions : Warns if PAML run fails.
               Throws if PAML returns multiple result sets (unlikely).
  Caller     : General

=cut

sub run {
  my ($self, $input_seq) = @_;

  $self->_query_seq($input_seq)
    if $input_seq;

  # Derive a list of sequences that look like duplications of 
  # the query sequence.

  my $seq_ids = $self->_find_recent_duplications($self->_query_seq);

  # Add the id of our query seq, or it will be omitted.

  push (@$seq_ids, $self->_query_seq->display_id);

  unless (scalar @$seq_ids > 1) {
    print "No homologous matches were found that satisfied the match criteria.\n";
    return 0
  }

  # Perform a codon based alignment of our sequences.

  my $seqs = $self->_fetch_seqs($seq_ids);

  my $cba = 
    Bio::EnsEMBL::Pipeline::GeneDuplication::CodonBasedAlignment->new(
       -genetic_code => $self->_genetic_code);

  $cba->sequences($seqs);

  my $aligned_seqs = $cba->run_alignment;

  $self->alignment($aligned_seqs);

  # Run PAML with these aligned sequences.

  my $parser = $self->_run_pairwise_paml($aligned_seqs);

  my @results;

  eval {
    # This is a bit stupid, but we dont know until here
    # whether our run has been successful.
    while (my $result = $parser->next_result()) {
      push (@results, $result)
    }
  };

  $self->throw("PAML run was unsuccessful.\n$@") 
    if $@;

  unless (@results) {
print $@;
    print "Duplications not found for this gene.\n";
    return 0
  }

  $self->throw("There are more than two sets of results returned from\n" .
	       "the PAML parser.  This was not expected.") 
    if scalar @results > 1;

  return $self->_extract_results($results[0])  
}


### Hit Chooser Methods ###

=head2 _find_recent_duplications

  Args[1]    : Bio::Seq query sequence
  Example    : none
  Description:
  Returntype :
  Exceptions :
  Caller     : General

=cut

sub _find_recent_duplications {
  my ($self, $query) = @_;

  # We are looking for duplicates of the query gene
  # in our blast database.
  $self->_query_seq($query) if $query;

  my $bplite_report;

  eval{
    $bplite_report = $self->_blast_obj->run;
  };

  $self->throw("Blast did not run successfully.  Blast program was [".
	       $self->_blast_program."].  Index type was [".
	       $self->_blast_index_type."].")
    if $@;

  $self->throw("Blast process did not return a report.")
    unless ($bplite_report->isa("Bio::Tools::BPlite"));

  return $self->_process_for_same_species_duplicates($bplite_report);
}


=head2 _process_for_same_species_duplicates

  Args[1]    :
  Example    :
  Description: This is the main algorithmic implementation.  See the 
               docs (yeah, right) for an explanation of what is going 
               on here.
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _process_for_same_species_duplicates {
  my ($self, $bplite_report) = @_;

  # Process our blast report.  For each blast hit to our query sequence:
  #   * throw away self matches (if any)
  #   * filter by identity
  #   * filter by coverage
  #   * calculate genetic distance between each subject and the query
  #   * add subject sequence to correct species hash

  my %species_hash;
  my %hit_distance;
  my $have_an_outgroup = 0;
  my $report_empty = 1;

 PARTITION_HITS:
  while (my $sbjct = $bplite_report->nextSbjct){

    $report_empty = 0; # Hits have been found.

    # Mangle the BPLite::Sbjct object for its own good.  Quite 
    # often the hit ids parsed by BPLite include the whole 
    # Fasta header description line.  This is problematic if 
    # sequence ids need to be compared or a hash is keyed on 
    # this sequence id.  Here we simply lop the description
    # from each Sbjct->name, if there is one.
    $sbjct = $self->_fix_sbjct($sbjct);

    # It appears that the BPLite::Sbjct object only allows 
    # HSPs to be accessed once (as this process is closely 
    # tied to the parsing of the Blast report).  Hence, here
    # we loop through them all here and store them in an 
    # array.

    my @hsps;

    while (my $hsp = $sbjct->nextHSP) {
      push (@hsps, $hsp);
    }

    # Skip hit if it is a match to self.

    next PARTITION_HITS
      if ($self->_query_seq->display_id eq $sbjct->name);

    # First, filter by identity

    my $hit_identity = $self->_hit_identity(\@hsps);

    next PARTITION_HITS
      unless ($hit_identity >= $self->_identity_cutoff);

    # Second, filter by coverage

    next PARTITION_HITS
      unless ($self->_appraise_hit_coverage($sbjct, \@hsps));

    # Third, filter by genetic distance.

    $hit_distance{$sbjct->name} 
      = $self->_calculate_pairwise_distance(
            $self->_query_seq->display_id, 
	    $sbjct->name,
	    'synonymous');

    # Third, partition hits according to their species.  The species
    # from which the subject is derived is determined by a
    # regular expression match to the sequence id.

    my $query_regex = $self->_regex_query_species;

    if ($sbjct->name =~ /$query_regex/) {

      push(@{$species_hash{$self->_regex_query_species}}, $sbjct);

      next PARTITION_HITS;
    } else {

      foreach my $regex (@{$self->{_regex_outgroup_species}}) {
	if ($sbjct->name =~ /$regex/){
	  $have_an_outgroup = 1;
	  push (@{$species_hash{$regex}}, $sbjct);
	  next PARTITION_HITS;
	}
      }

    }

    $self->throw("Didnt match hit id to any regex [".$sbjct->name."].");
  }


  # Make a comment and return if the blast report contained no hits. 
  if ($report_empty) {
    print "Did not find hits to query sequence.\n";
    return [] 
  }

  # Sort our hits by their distance to the query sequence.

  my %sorted_species_hits;

  foreach my $species (keys %species_hash) {

    my @sorted_hits 
      = sort {$hit_distance{$a->name} <=> $hit_distance{$b->name}} 
	@{$species_hash{$species}};
    $sorted_species_hits{$species} = \@sorted_hits;
  }

  # Accept all query species hits with a distance less than
  # the distance to the most related outgroup species.

  $self->outgroup_distance($self->_distance_cutoff);
  my $closest_outgroup_distance = $self->_distance_cutoff;

  foreach my $regex (@{$self->_regex_outgroup_species}){
      next
        unless $sorted_species_hits{$regex};

    if ((defined $sorted_species_hits{$regex}->[0]->name) && 
	(defined $hit_distance{$sorted_species_hits{$regex}->[0]->name}) &&
	($hit_distance{$sorted_species_hits{$regex}->[0]->name} < $closest_outgroup_distance) && 
	($hit_distance{$sorted_species_hits{$regex}->[0]->name} > 0)) {

      $closest_outgroup_distance = $hit_distance{$sorted_species_hits{$regex}->[0]->name};
    }
  }

  $self->outgroup_distance($closest_outgroup_distance);

  my @accepted_ids;

  foreach my $sbjct (@{$sorted_species_hits{$self->_regex_query_species}}) {

    if ($hit_distance{$sbjct->name} <= $closest_outgroup_distance) {
      push (@accepted_ids, $sbjct->name);

    } else {
      last;
    }
  }

  return \@accepted_ids;
}


### Utility Methods ###

=head2 _run_pairwise_paml

  Args       : An arrayref to a set of aligned Bio::Seq objects.
  Example    : none
  Description: Uses an array of aligned Bio::Seq objects to execute
               PAML in pairwise mode.
  Returntype : Bio::Tools::Phylo::PAML
  Exceptions : none
  Caller     : $self->run

=cut

sub _run_pairwise_paml {
  my ($self, $aligned_seqs) = @_;

  my $paml = Bio::EnsEMBL::Pipeline::GeneDuplication::PAML->new(
			     '-work_dir'     => $self->_work_dir,
			     '-executable'   => $self->_codeml,
			     '-aligned_seqs' => $aligned_seqs,
			     '-runmode'      => '-2',
			     '-seqtype'      => '1',
			     '-model'        => '0',
			     '-nssites'      => '0',
			     '-icode'        => ($self->_genetic_code) - 1
			    );

  my $parser;

  eval{
    $parser = $paml->run_codeml
  };

  $self->throw("Paml execution failed.\n$@")
    if $@;

  return $parser;
}


=head2 _calculate_pairwise_distance

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _calculate_pairwise_distance {
  my ($self, $input_id_1, $input_id_2, $distance_measure) = @_;

  # Default to using the synonymous genetic distance, unless the
  # user has deliberately set this.
  $distance_measure = 'synonymous' unless $distance_measure;

  my @seqs = ($self->_fetch_seq($input_id_1), 
	      $self->_fetch_seq($input_id_2));

  $self->throw("Didnt correctly obtain two sequences for alignment.")
    unless scalar @seqs == 2;

  my $align = $self->_pairwise_align(\@seqs);

  my $paml_parser;

  eval {
    $paml_parser = $self->_run_pairwise_paml($align);
  };

  if ($@){
    $self->throw("Pairwise use of PAML failed [$input_id_1]vs[$input_id_2].\n$@");
    return 0
  }

  my $result;
  my $NGmatrix;

  eval {
    $result = $paml_parser->next_result();
    $NGmatrix = $result->get_NGmatrix();
  };

  if ($@){
    $self->warn("PAML failed to give a file that could be parsed.  No doubt PAML threw an error!\n$@");
    return 0
  }

  return $NGmatrix->[0]->[1]->{dN} if $distance_measure eq 'nonsynonymous';
  return $NGmatrix->[0]->[1]->{dS} if $distance_measure eq 'synonymous';
  return 0;
}


=head2 _pairwise_align

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _pairwise_align {
  my ($self, $seqs) = @_;

  $self->throw("Pairwise alignment was only expecting two sequences.")
    unless ((scalar @$seqs) == 2);

  my $cba 
    = Bio::EnsEMBL::Pipeline::GeneDuplication::CodonBasedAlignment->new(
	-genetic_code => 1);

  $cba->sequences($seqs);

  my $aligned_seqs = $cba->run_alignment;

  return $aligned_seqs
}


=head2 _appraise_hit_coverage

  Args[1]    :
  Example    :
  Description:
  Returntype : 0 or 1
  Exceptions :
  Caller     :

=cut

sub _appraise_hit_coverage{
  my ($self, $sbjct, $hsps) = @_;

  # First, throw out hits that are way longer than
  # the query.

  my $sbjct_length 
    = $self->_fetch_seq($sbjct->name)->length;

  return 0 
    if ($sbjct_length > 
	((2 - $self->_coverage_cutoff) * $self->_query_seq->length));

  # If still here, look at all the hits along the length of the 
  # query and tally the collective coverage of the hits.

  my @query_coverage;

  foreach my $hsp (@$hsps) {

    for (my $base_position = $hsp->query->start; 
	 $base_position <= $hsp->query->end;
	 $base_position++){
      $query_coverage[$base_position]++;
    }
  }

  my $covered_bases = 0;

  foreach my $base (@query_coverage){
    $covered_bases++ if $base;
  }

  # Return true if good coverage exists.

  return 1 if ($covered_bases >= $self->_coverage_cutoff * $self->_query_seq->length);

  # Otherwise return false.
  return 0;
}


=head2 _extract_results

  Args[1]    : Bio::Tools::Phylo::PAML::Result
  Example    : none
  Description: Derive the PAML result object (and output matrix) into 
               the much simpler GeneDuplication::Result object.
  Returntype : Bio::EnsEMBL::Pipeline::GeneDuplication::Result
  Exceptions : none
  Caller     : $self->run

=cut

sub _extract_results {
  my ($self, $result) = @_;

  my $query_id = $self->_query_seq->display_id;

  my $matrix;

  $matrix = $result->get_MLmatrix() 
    if $self->_distance_method =~ /ML/;
  $matrix = $result->get_NGmatrix() 
    if $self->_distance_method =~ /NeiGojobori/;

  $self->throw("Failed to retrieve a result matrix from ".
	       "the PAML result.")
    unless $matrix;

  my @otus = $result->get_seqs();

  my $result_obj = Bio::EnsEMBL::Pipeline::GeneDuplication::Result->new(
		       -id              => $query_id,
		       -distance_method => $self->_distance_method);

  $result_obj->matrix($matrix);
  $result_obj->otus(\@otus);

  for(my $i = 0; $i < scalar @otus; $i++){
    for (my $j = $i+1; $j < scalar @otus; $j++){
      $result_obj->add_match($otus[$i]->display_id,
			     $otus[$j]->display_id,
			     $matrix->[$i]->[$j]->{'dN'},
			     $matrix->[$i]->[$j]->{'dS'},
			     $matrix->[$i]->[$j]->{'N'} ? $matrix->[$i]->[$j]->{'N'} : 0,
			     $matrix->[$i]->[$j]->{'S'} ? $matrix->[$i]->[$j]->{'S'} : 0,
			     $matrix->[$i]->[$j]->{'lnL'} ? $matrix->[$i]->[$j]->{'lnL'} : 0);
    }
  }

  return $result_obj
}


=head2 _fix_sbjct

  Args[1]    :
  Example    :
  Description: A work-around for a BPLite::Sbjct annoyance.  The 
               sbjct->name object returns the whole fasta description 
               line for a subject hit.  If the input fasta sequence 
               file includes more than an id on the description line, 
               this will be passed back every time the name method is 
               called.  This is a real pest is you are trying to 
               match ids via a regex or use the ids as hash keys.
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _fix_sbjct {
  my ($self, $sbjct) = @_;

  my $sbjct_name = $sbjct->name;

  $sbjct_name =~ s/\W*(\w+).*/$1/;

  # BAD!
  $sbjct->{NAME} = $sbjct_name;

  return $sbjct;
}


=head2 _hit_identity

  Args[1]    :
  Example    :
  Description:
  Returntype : 
  Exceptions :
  Caller     :

=cut

sub _hit_identity{
  my ($self, $hsps) = @_;

  my $tally_query_length = 0;
  my $tally_matched_bases = 0;

  foreach my $hsp (@$hsps) {
    $tally_query_length  += length($hsp->querySeq);
    $tally_matched_bases += $hsp->positive;
  }

  if ($tally_matched_bases && $tally_query_length){
    return $tally_matched_bases/$tally_query_length;
  }

  return 0
}


=head2 alignment

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub alignment {
  my $self = shift; 

  if (@_) {
    $self->{_alignment} = shift;
  }

  return $self->{_alignment};
}


=head2 outgroup_distance

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub outgroup_distance {
  my $self = shift; 

  if (@_) {
    $self->{_outgroup_distance} = shift;
  }

  return $self->{_outgroup_distance};
}


### Sequence fetching ###

=head2 _fetch_seq

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _fetch_seq {
  my ($self, $id) = @_;

  $self->throw("Cant fetch sequence without an id.")
    unless $id;

  $self->{_cache} = {}
    unless $self->{_cache};

  if ($self->{_cache}->{$id}){
    return $self->{_cache}->{$id}
  }

  my $seq = $self->_seq_fetcher->fetch($id);

  $self->throw("Sequence fetch failed for id [$id].")
    unless ($seq && $seq->isa("Bio::Seq"));

  $self->{_cache}->{$seq->display_id} = $seq;

  return $seq
}


=head2 _fetch_seqs

  Args       : An arrayref of string sequence ids.
  Example    : none
  Description: An alias to $self->_fetch_seq, but handles 
               multiple sequences.
  Returntype : Arrayref of Bio::Seq
  Exceptions : none
  Caller     : $self->run

=cut

sub _fetch_seqs {
  my ($self, $seq_ids) = @_;

  my @seqs;

  foreach my $seq_id (@$seq_ids){
    push (@seqs, $self->_fetch_seq($seq_id));
  }

  return \@seqs;
}


=head2 _force_cache

  Args[1]    : Bio::Seq
  Example    : $self->_force_cache($seq);
  Description: Allows a sequence to be manually added to the seqfetcher 
               cache.  This is useful for coping with user supplied 
               sequences (eg. passed as a query sequence) that dont 
               exist in any database.
  Returntype : 1
  Exceptions : Warns if sequence already exists in cache.  Throws if
               a defined sequence isnt supplied.
  Caller     : 

=cut

sub _force_cache {
  my ($self, $seq) = @_;

  $self->throw("Trying to add something odd to the sequence cache [$seq].")
    unless (defined $seq);

  if ($self->{_cache}->{$seq->display_id}){
    $self->warn('Sequence [' . $seq->display_id . 
		'] already exists in cache, but will replace.');
  }

  $self->{_cache}->{$seq->display_id} = $seq;

  return 1
}


=head2 _seq_fetcher

  Args       : (optional) A seqfetcher of any variety, as long as 
               it has a 'fetch' method.
  Example    : none
  Description: Holds SeqFetcher object.
  Returntype : Bio::EnsEMBL::Pipeline::SeqFetcher::xxx
  Exceptions : none
  Caller     : $self->_candidate_hits, $self->_fetch_seqs

=cut

sub _seq_fetcher {
  my $self = shift;

  $self->{_seq_fetcher} = shift if @_;

  if (! $self->{_seq_fetcher}){
    $self->{_seq_fetcher} = 
      Bio::EnsEMBL::Pipeline::SeqFetcher::FetchFromBlastDB->new(
				     -db => $self->_blastdb);
  }

  return $self->{_seq_fetcher};
}


### Blast-related Getter/Setters ###

=head2 _dbfile

  Args       : (optional) String
  Example    : none
  Description: Holds the filename of the blast database.
  Returntype : String.
  Exceptions : none
  Caller     : $self->new, $self->_hit_chooser.

=cut

sub _dbfile {
  my $self = shift;

  return $self->_blastdb->dbfile
}


=head2 _blast_obj

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _blast_obj {
  my $self = shift;

  if (@_){
    $self->{_blast_obj} = shift;
    return
  }

  unless ($self->{_blast_obj}){

    # Create a new blast object with our mixed species input database.

    $self->{_blast_obj} 
      = Bio::EnsEMBL::Pipeline::Runnable::MinimalBlast->new(
		 -program         => $self->_blast_program,
		 -blastdb         => $self->_blastdb,
		 -queryseq        => $self->_query_seq,
		 -options         => '',
		 -workdir         => $self->_work_dir,
		 -identity_cutoff => $self->_identity_cutoff);
  }


  return $self->{_blast_obj};
}


=head2 _blastdb

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _blastdb {
  my $self = shift;

  if (@_) {
    $self->{_blastdb} = shift;

    $self->throw("Blast database must be a Bio::EnsEMBL::Pipeline::Runnable::BlastDB.")
      unless ($self->{_blastdb}->isa("Bio::EnsEMBL::Pipeline::Runnable::BlastDB"));

    $self->throw("Blast database has not been formatted.")
      unless $self->{_blastdb}->db_formatted;

    $self->throw("Blast database has been built without the " . 
		 "make_fetchable_index flag set (and this is " .
		 "a problem because the database can not be " . 
		 "used for sequence fetching).")
      unless $self->{_blastdb}->make_fetchable_index
  }

  $self->throw("Blast database object not set.")
    unless ($self->{_blastdb});

  return $self->{_blastdb};
}


=head2 _blast_program

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _blast_program {
  my $self = shift;

  if (@_){
    $self->{_blast_program} = shift;
    return
  }

  $self->{_blast_program} = $DEFAULT_BLAST_PROGRAM
    unless $self->{_blast_program};

  return $self->{_blast_program};
}


=head2 _blast_index_type

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _blast_index_type {
  my $self = shift;

  return $self->_blastdb->index_type;
}


### Getter/Setters ###

=head2 _query_seq

  Args       : (optional) Bio::Seq
  Example    : none
  Description: Holds the query sequence for which we are searching for duplicates.
  Returntype : Bio::Seq
  Exceptions : none
  Caller     : $self->run, $self->_extract_results

=cut

sub _query_seq {
  my $self = shift;

  if (@_) {
    $self->{_query_seq} = shift;

    $self->throw("Query sequence is not a Bio::Seq object [" . 
		 $self->{_query_seq} . "]")
      unless $self->{_query_seq}->isa("Bio::Seq");

    $self->throw("Cant add query sequence to sequence cache manually.")
      unless $self->_force_cache($self->{_query_seq});

    return
  }

  $self->throw("Query sequence has not been set.")
    unless $self->{_query_seq};

  return $self->{_query_seq};
}


=head2 _work_dir

  Args       : (optional) String.
  Example    : none
  Description: Holds the path to the working directory.
  Returntype : String.
  Exceptions : none
  Caller     : $self->new, $self->_hit_chooser, $self->_run_pairwise_paml.

=cut

sub _work_dir {
  my $self = shift;

  if (@_) {
    $self->{_work_dir} = shift;
    return
  }

  $self->throw("Work directory not set.")
    unless $self->{_work_dir};

  return $self->{_work_dir};
}


=head2 _identity_cutoff

  Args       : (optional) an int or a float - a percentage value anyways.
  Example    : none
  Description: Holds identity cutoff percentage value.
  Returntype : A float value
  Exceptions : none
  Caller     : $self->new, $self->_hit_chooser.

=cut

sub _identity_cutoff {
  my $self = shift;

  if (@_) {
    $self->{_identity_cutoff} = shift;
    $self->{_identity_cutoff} /= 100 if $self->{_identity_cutoff} > 1;
    return
  }

  $self->throw("Blast match identity cutoff has not been set.")
    unless $self->{_identity_cutoff};

  return $self->{_identity_cutoff};
}


=head2 _coverage_cutoff

  Args       : (optional) an int or a float - a percentage value anyways.
  Example    : none
  Description: Holds coverage cutoff percentage value.
  Returntype : A float value.
  Exceptions : none
  Caller     : $self->new, $self->_hit_chooser.

=cut

sub _coverage_cutoff {
  my $self = shift; 

  if (@_) {
    $self->{_coverage_cutoff} = shift;
    $self->{_coverage_cutoff} /= 100 if $self->{_coverage_cutoff} > 1;
    return
  }

  $self->throw("The coverage cutoff has not been set.")
    unless $self->{_coverage_cutoff};

  return $self->{_coverage_cutoff};
}


=head2 _distance_cutoff

  Args[1]    :
  Example    :
  Description:
  Returntype :
  Exceptions :
  Caller     :

=cut

sub _distance_cutoff {
  my $self = shift; 

  if (@_) {
    $self->{_distance_cutoff} = shift;
    return
  }

  $self->{_distance_cutoff} = $DEFAULT_DISTANCE_CUTOFF
    unless $self->{_distance_cutoff};

  return $self->{_distance_cutoff};
}


=head2 _regex_query_species

  Args       : String
  Example    : $self->_regex_query_species('ENSG')
  Description: Holds a regex string that will match the id of
               any sequence from the query species.
  Returntype : String or 1
  Exceptions : Throws when regex is not set.
  Caller     : $self->new, $self->_hit_chooser

=cut

sub _regex_query_species {
  my $self = shift;

  if (@_) {
    $self->{_regex_query_species} = shift;
    return
  }

  $self->throw("The regular expression used to match the sequence"
	       ." ids from the query species has not been set.")
    unless $self->{_regex_query_species};

  return $self->{_regex_query_species};
}


=head2 _regex_outgroup_species

  Args       : ref to an array of strings
  Example    : $self->_regex_outgroup_species(['ENSRNO', 'ENSMUS']);
  Description: Holds an array of regexs that will allow the sequence
               id of all non-query species sequences to be matched.
  Returntype : arrayref
  Exceptions : Warns if called while unset.
  Caller     : $self->new, $self->_hit_chooser

=cut

sub _regex_outgroup_species {
  my $self = shift; 

  if (@_) {
    $self->{_regex_outgroup_species} = shift;
    return
  }

  $self->warn('No outgroup species regex provided.  ' .
	      'This may or may not be what you intend.')
    unless $self->{_regex_outgroup_species};

  return $self->{_regex_outgroup_species};
}


=head2 _genetic_code

  Args       : int
  Example    : $self->_genetic_code(1);
  Description: Holds an integer representing the genetic code.  To 
               choose the correct integer consult the documentation 
               used by the Bio::Seq->translate method.  1 is universal, 
               2 is vertebrate mitochondria.
  Returntype : int
  Exceptions : Warns if called while unset.
  Caller     : $self->new, $self->run, $self->_run_pairwise_paml

=cut

sub _genetic_code {
  my $self = shift; 

  if (@_) {
    $self->{_genetic_code} = shift;
    return
  }

  $self->throw('Genetic code unset.')
    unless $self->{_genetic_code};

  return $self->{_genetic_code};
}


=head2 _distance_method

  Args       : String
  Example    : 
  Description: 
  Returntype : 
  Exceptions : Throws if set to an unrecognised string.
  Caller     : 

=cut

sub _distance_method {
  my $self = shift; 

  if (@_) {
    $self->{_distance_method} = shift;

    unless ($self->{_distance_method} =~ /NeiGojobori/i |
	    $self->{_distance_method} =~ /ML/i){
      $self->throw("Distance method must be set to either " .
		   "NeiGojobori or ML, not [".
		   $self->{_distance_method}."]");
    }
  }

  $self->{_distance_method} = $DEFAULT_DISTANCE_METHOD
    unless $self->{_distance_method};

  return $self->{_distance_method};
}


=head2 _codeml

  Args       : [optional] String
  Example    : $self->_codeml('/path/to/codeml')
  Description: Holds the path to the codeml executable
  Returntype : String
  Exceptions : Throws if a full path is included, but the 
               file is not executable.
  Caller     : $self->new, $self->_run_pairwise_paml

=cut

sub _codeml {
  my $self = shift; 

  if (@_) {
    $self->{_codeml} = shift;
    return
  }

  $self->{_codeml} = 'codeml'
    unless $self->{_codeml};

  # If it looks like our executable comes with a full 
  # path, check that it will work.

  $self->throw("codeml executable not found or not " .
	       "executable. Trying to execute path " .
	       "[". $self->{_codeml} ."]")
    if ($self->{_codeml} =~ /^\//
	& !-x $self->{_codeml});

  return $self->{_codeml};
}

return 1