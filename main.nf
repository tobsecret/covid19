#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/covid19
========================================================================================
 nf-core/covid19 Analysis Pipeline.

 #### Homepage / Documentation
 https://github.com/nf-core/covid19
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/covid19 --input samplesheet.csv --genome hg38 -profile docker

    Mandatory arguments:
      --input [file]                  Comma-separated file containing information about the samples in the experiment (see docs/usage.md)
      --fasta [file]                  Path to Fasta reference. Not mandatory when using reference in iGenomes config via --genome
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --genome [str]                  Name of iGenomes reference
      --bwa_index [file]              Full path to directory containing BWA index including base name i.e. /path/to/index/genome.fa
      --minimap2_index [file]         Full path to Minimap2 '.mmi' index file
      --save_reference [bool]         If generated by the pipeline save the BWA index in the results directory (Default: false)

    Trimming
      --skip_trimming [bool]          Skip the adapter trimming step (Default: false)
      --save_trimmed [bool]           Save the trimmed FastQ files in the results directory (Default: false)

    Alignments
      --save_align_intermeds [bool]   Save the intermediate BAM files from the alignment step (Default: false)

    QC
      --skip_fastqc [bool]            Skip FastQC (Default: false)
      --skip_nanoplot [bool]          Skip NanoPlot (Default: false)
      --skip_multiqc [bool]           Skip MultiQC (Default: false)
      --skip_qc [bool]                Skip all QC steps apart from MultiQC (Default: false)

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                SET UP CONFIGURATION VARIABLES                       -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

////////////////////////////////////////////////////
/* --         DEFAULT PARAMETER VALUES         -- */
////////////////////////////////////////////////////

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
   exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// Configurable variables
params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
params.bwa_index = params.genome ? params.genomes[ params.genome ].bwa ?: false : false

////////////////////////////////////////////////////
/* --          VALIDATE INPUTS                 -- */
////////////////////////////////////////////////////

if (params.input) { ch_input = file(params.input, checkIfExists: true) } else { exit 1, "Samplesheet file not specified!" }

if (params.fasta) {
    lastPath = params.fasta.lastIndexOf(File.separator)
    bwa_base = params.fasta.substring(lastPath+1)
    ch_fasta = file(params.fasta, checkIfExists: true)
} else {
    exit 1, "Fasta file not specified!"
}

if (params.bwa_index) {
    lastPath = params.bwa_index.lastIndexOf(File.separator)
    bwa_dir =  params.bwa_index.substring(0,lastPath+1)
    bwa_base = params.bwa_index.substring(lastPath+1)
    Channel
        .fromPath(bwa_dir, checkIfExists: true)
        .set { ch_bwa_index }
}

if (params.minimap2_index) { ch_minimap2_index = Channel.fromPath(params.minimap2_index, checkIfExists: true) }

////////////////////////////////////////////////////
/* --          CONFIG FILES                    -- */
////////////////////////////////////////////////////

ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

////////////////////////////////////////////////////
/* --                   AWS                    -- */
////////////////////////////////////////////////////

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                       HEADER LOG INFO                               -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Samplesheet']            = params.input
summary['Genome']                 = params.genome ?: 'Not supplied'
summary['Fasta File']             = params.fasta
if (params.bwa_index)             summary['BWA Index'] = params.bwa_index
if (params.minimap2_index)        summary['Minimap2 Index'] = params.minimap2_index
summary['Save Genome Index']      = params.save_reference ? 'Yes' : 'No'
if (params.skip_trimming)         summary['Skip Trimming'] = 'Yes'
if (params.save_trimmed)          summary['Save Trimmed'] = 'Yes'
if (params.save_align_intermeds)  summary['Save Intermeds'] =  'Yes'
if (params.skip_qc)               summary['Skip QC'] = 'Yes'
if (params.skip_fastqc)           summary['Skip FastQC'] = 'Yes'
if (params.skip_nanoplot)  summary['Skip NanoPlot']  = 'Yes'
if (params.skip_multiqc)          summary['Skip MultiQC'] = 'Yes'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                     PARSE DESIGN FILE                               -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING: Reformat samplesheet and check validitiy
 */
process CHECK_SAMPLESHEET {
    tag "$samplesheet"
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file samplesheet from ch_input

    output:
    file "*.csv" into ch_samplesheet_reformat

    script:  // This script is bundled with the pipeline, in nf-core/covid19/bin/
    """
    check_samplesheet.py $samplesheet samplesheet_reformat.csv
    """
}

// Function to get list of [ sample, single_end?, long_reads?, [ fastq_1, fastq_2 ] ]
def validate_input(LinkedHashMap sample) {
    def sample_id = sample.sample_id
    def single_end = sample.single_end.toBoolean()
    def long_reads = sample.long_reads.toBoolean()
    def fastq_1 = sample.fastq_1
    def fastq_2 = sample.fastq_2

    def array = []
    if (single_end || long_reads) {
        array = [ sample_id, single_end, long_reads, [ file(fastq_1, checkIfExists: true) ] ]
    } else {
        array = [ sample_id, single_end, long_reads, [ file(fastq_1, checkIfExists: true), file(fastq_2, checkIfExists: true) ] ]
    }
    return array
}

/*
 * Create channels for input fastq files
 */
ch_samplesheet_reformat
    .splitCsv(header:true, sep:',')
    .map { validate_input(it) }
    .into { ch_reads_nanoplot;
            ch_reads_fastqc;
            ch_reads_bwa;
            ch_reads_minimap2 }

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                     PREPARE REFERENCE FILES                         -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * PREPROCESSING: Build BWA index
 */
if (!params.bwa_index) {
    process BWA_INDEX {
        tag "$fasta"
        label 'process_high'
        publishDir path: { params.save_reference ? "${params.outdir}/genome" : params.outdir },
            saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta

        output:
        file "BWAIndex" into ch_bwa_index

        script:
        """
        bwa index -a bwtsw $fasta
        mkdir BWAIndex && mv ${fasta}* BWAIndex
        """
    }
}

/*
 * PREPROCESSING: Build Minimap2 index
 */
if (!params.minimap2_index) {
    process MINIMAP2_INDEX {
        tag "$fasta"
        label 'process_medium'
        publishDir path: { params.save_reference ? "${params.outdir}/genome/Minimap2Index" : params.outdir },
            saveAs: { params.save_reference ? it : null }, mode: params.publish_dir_mode

        input:
        file fasta from ch_fasta

        output:
        file "*.mmi" into ch_minimap2_index

        script:
        """
        minimap2 -ax map-ont  -t $task.cpus -d ${fasta}.mmi $fasta
        """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        FASTQ QC                                     -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 1: Illumina and Nanopore FastQC before trimming
 */
process FASTQC {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      filename.endsWith(".zip") ? "zips/$filename" : "$filename"
                }

    when:
    !params.skip_fastqc && !params.skip_qc

    input:
    set val(sample), val(single_end), val(long_reads), file(reads) from ch_reads_fastqc

    output:
    file "*.{zip,html}" into ch_fastqc_reports_mqc

    script:
    // Added soft-links to original fastqs for consistent naming in MultiQC
    if (single_end || long_reads) {
        """
        [ ! -f  ${sample}.fastq.gz ] && ln -s $reads ${sample}.fastq.gz
        fastqc -q -t $task.cpus ${sample}.fastq.gz
        """
    } else {
        """
        [ ! -f  ${sample}_1.fastq.gz ] && ln -s ${reads[0]} ${sample}_1.fastq.gz
        [ ! -f  ${sample}_2.fastq.gz ] && ln -s ${reads[1]} ${sample}_2.fastq.gz
        fastqc -q -t $task.cpus ${sample}_1.fastq.gz
        fastqc -q -t $task.cpus ${sample}_2.fastq.gz
        """
    }
}

/*
 * STEP 2: Nanopore FastQ QC using NanoPlot
 */
process NANOPLOT {
    tag "$sample"
    label 'process_low'
    publishDir "${params.outdir}/nanoplot/${sample}", mode: params.publish_dir_mode

    when:
    !params.skip_nanoplot && !params.skip_qc && long_reads

    input:
    set val(sample), val(single_end), val(long_reads), file(reads) from ch_reads_nanoplot

    output:
    file "*.{png,html,txt,log}"

    script:
    """
    NanoPlot -t $task.cpus --fastq $reads
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        ADAPTER TRIMMING                             -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 2: Adapter trimming
 */

process FASTP {
    tag "$sample"
    label 'process_medium'
    publishDir "${params.outdir}/fastp", mode: params.publish_dir_mode
    
    when:
    !long_reads

    input:
    set val(sample), val(single_end), val(long_reads), file(reads) from ch_reads_bwa

    output:
    set val(sample), val(single_end), val(long_reads), file("*trimmed.fastq{,.gz}") into ch_reads_trimmed

    script:
    fastp_params = "-q 20 -u 20 -l 50"
    if (single_end) {
        out_read = (reads.getExtension() == "gz") ? "${sample}.trimmed.fastq.gz" : "${sample}.trimmed.fastq"
        """
        fastp -i ${reads} -o $out_read $fastp_params
        """
    } else {
        out_read1 = (reads[0].getExtension() == "gz") ? "${sample}_1.trimmed.fastq.gz" : "${sample}_1.trimmed.fastq"
        out_read2 = (reads[1].getExtension() == "gz") ? "${sample}_2.trimmed.fastq.gz" : "${sample}_2.trimmed.fastq"

        """
        fastp -i ${reads[0]} -I ${reads[1]} -o $out_read1 -O $out_read2 $fastp_params
        """
    }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        ALIGN                                        -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

/*
 * STEP 3.1: Map Illumina read(s) with bwa mem
 */
process BWA_MEM {
    tag "$sample"
    label 'process_high'
    if (params.save_align_intermeds) {
        publishDir path: "${params.outdir}/bwa", mode: params.publish_dir_mode
    }

    when:
    !long_reads

    input:
    set val(sample), val(single_end), val(long_reads), file(reads) from ch_reads_trimmed
    file index from ch_bwa_index.collect()

    output:
    set val(sample), val(single_end), val(long_reads), file("*.bam") into ch_bwa_bam

    script:
    rg = "\'@RG\\tID:${sample}\\tSM:${sample.split('_')[0..-2].join('_')}\\tPL:ILLUMINA\\tLB:${sample}\\tPU:1\'"
    """
    bwa mem \\
        -t $task.cpus \\
        -M \\
        -R $rg \\
        ${index}/${bwa_base} \\
        $reads \\
        | samtools view -@ $task.cpus -b -h -F 0x0100 -O BAM -o ${sample}.bam -
    """
}

/*
 * STEP 3.1: Map Nanopore read(s) with Minimap2
 */
process MIMIMAP2_ALIGN {
    tag "$sample"
    label 'process_medium'
    if (params.save_align_intermeds) {
        publishDir path: "${params.outdir}/minimap2", mode: params.publish_dir_mode
    }

    when:
    long_reads

    input:
    set val(sample), val(single_end), val(long_reads), file(reads) from ch_reads_minimap2
    file index from ch_minimap2_index.collect()

    output:
    set val(sample), val(single_end), val(long_reads), file("*.bam") into ch_minimap2_bam

    script:
    """
    minimap2 \\
        -ax map-ont \\
        -t $task.cpus \\
        $index \\
        $reads \\
        | samtools view -@ $task.cpus -b -h -O BAM -o ${sample}.bam -
    """
}

/*
 * STEP 3.2: Convert BAM to coordinate sorted BAM
 */
process SORT_BAM {
    tag "$sample"
    label 'process_medium'
    publishDir path: "${params.outdir}/${aligner}", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (params.save_align_intermeds) {
                          if (filename.endsWith(".flagstat")) "samtools_stats/$filename"
                          else if (filename.endsWith(".idxstats")) "samtools_stats/$filename"
                          else if (filename.endsWith(".stats")) "samtools_stats/$filename"
                          else filename
                      }
                }

    input:
    set val(sample), val(single_end), val(long_reads), file(bam) from ch_bwa_bam.concat(ch_minimap2_bam)

    output:
    set val(sample), val(single_end), val(long_reads), file("*.sorted.{bam,bam.bai}") into ch_sort_bam
    file "*.{flagstat,idxstats,stats}" into ch_sort_bam_flagstat_mqc

    script:
    aligner = long_reads ? "minimap2" : "bwa"
    """
    samtools sort -@ $task.cpus -o ${sample}.sorted.bam -T $sample $bam
    samtools index ${sample}.sorted.bam
    samtools flagstat ${sample}.sorted.bam > ${sample}.sorted.bam.flagstat
    samtools idxstats ${sample}.sorted.bam > ${sample}.sorted.bam.idxstats
    samtools stats ${sample}.sorted.bam > ${sample}.sorted.bam.stats
    """
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                        BAM POST-ANALYSIS                            -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////




///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
/* --                                                                     -- */
/* --                          MULTIQC                                    -- */
/* --                                                                     -- */
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-covid19-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/covid19 Workflow Summary'
    section_href: 'https://github.com/nf-core/covid19'

    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    NanoPlot --version &> v_nanoplot.txt
    echo \$(bwa 2>&1) > v_bwa.txt
    minimap2 --version &> v_minimap2.txt
    samtools --version > v_samtools.txt
    picard MarkDuplicates --version &> v_picard.txt  || true
    echo \$(R --version 2>&1) > v_R.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 10: MultiQC
 */
process MULTIQC {
    publishDir "${params.outdir}/multiqc", mode: params.publish_dir_mode

    when:
    !params.skip_multiqc

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from ch_fastqc_reports_mqc.collect().ifEmpty([])
    file ('samtools/*') from ch_sort_bam_flagstat_mqc.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    multiqc . -f $rtitle $rfilename $custom_config_file \\
        -m custom_content -m fastqc -m samtools -m picard
    """
}

/*
 * STEP 11: Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/covid19] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/covid19] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/covid19] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/covid19] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/covid19] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/covid19] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/covid19]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/covid19]${c_red} Pipeline completed with errors${c_reset}-"
    }

}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/covid19 v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
