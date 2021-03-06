version 1.0

workflow usherPlaceNewSamples {
    input {
        String prefix= "CDPH"
        String terra_project
        String workspace_name
        Array[String] table_name
        File public_meta
        File protobuf
        String public_json_bucket
        Int treesize = 500
    }
    parameter_meta {
        table_name : "List of Terra table names containing SARS-CoV-2 sequences and metadata"
        terra_project : "Project in which to find the table names"
        workspace_name : "Workspace containing terra_project"
        protobuf: "UShER-generated phylogenetic tree in protobuf format. The program will add the new samples to this tree."
        public_meta: "Metadata for the input protobuf tree containing sample names in first column"
        prefix: "A short string to prepend to the input sample IDs during the run. This is important if sample IDs are numeric: UShER will treat these as existing node IDs and ignore the sample."
        public_json_bucket: "Location for the output subtrees; files will be put in a subdirectory called jsontrees. This must be a public location so Nextstrain can pull in the trees for display. Note that the user's service account must have write access to this bucket."
        treesize: "Number of neighbors in the output json subtrees. If input samples end up in the same subtree, the matUtils output simply links both sample IDs to the same file."

    }
    call prefixSanityCheck { input: prefix=prefix }
    call parse_terratable { 
        input: 
            prefix = prefix,
            terra_project = terra_project,
            workspace_name = workspace_name,
            table_name = table_name,
            metatsv = public_meta
    }
    call gcs_copy_fafiles { 
        input: 
            falist = parse_terratable.gatherfastas, 
            prefix=prefix 
    }
    call getProblemVcf
    call mafft_align { 
        input : 
            sequences = gcs_copy_fafiles.combined_fasta, 
            ref_fasta = getProblemVcf.ref_fasta 
    }
    call faToVcf {
        input:
            fasta       = mafft_align.aligned_sequences,
            problem_vcf = getProblemVcf.problem_vcf
    }
    call usherAddSamples { 
        input: 
            vcf      = faToVcf.sample_vcf,
            protobuf = protobuf
    }
    call Extract {
        input: 
             tree_pb=usherAddSamples.new_tree,
             public_meta=public_meta,
             samples_meta=parse_terratable.sample_meta, 
             prefix=prefix,
             treesize=treesize,
             public_json_bucket=public_json_bucket
    }
    call gcs_copy {
        input:
            infiles = Extract.subtree_jsons, 
            gcs_uri_prefix = Extract.bucket
    }
    output {
        File noPassTable= parse_terratable.noPassIds
        File sample_meta = parse_terratable.sample_meta
        File newProtobuf = usherAddSamples.new_tree
        File urltable = Extract.out_html
        File subtree_assignments = Extract.out_tsv
	    File name_and_paui = Extract.specimen_mapped_to_paui
        File paui2url = Extract.paui_mapped_to_tree
        String subtree_link = "http://storage.googleapis.com/" + Extract.bucket + "/samples_subtrees.html"
    }
    meta {
        author: "Jeltje van Baren"
        email: "jeltje@soe.ucsc.edu"
        description: "Runs the UShER phylogenetic SARS-CoV-2 tree builder on samples in input tables; outputs json format subtrees for each sample"
    }
}

task prefixSanityCheck{
     meta { description: "No dashes, slashes or other nonsense in the input string" }
     input { String prefix }
     command <<<
         if [[ ! ~{prefix} =~ ^[A-Za-z0-9_]+$ ]]; then
             >&2 echo "prefix ~{prefix} contains unallowed character, only use A-Z, a-z, 0-9, _"
             exit 1
         fi
     >>>
    runtime {
        docker: "yatisht/usher:latest"
    }
}

task parse_terratable{
    input{
        String prefix 
        String terra_project
        String workspace_name
        Array[String] table_name
        File metatsv
    }
    meta {
        description: "Pull tables and select samples with decent sequences. Match Gisaid ID to those already in the UShER tree. Create metadata file"
        volatile: true
    }
    command <<<
    set -euo pipefail

    python3 <<CODE
import csv
import json
import collections
import re
from firecloud import api as fapi

workspace_project = '~{terra_project}'
workspace_name = '~{workspace_name}'
tnames = '~{sep=',' table_name}'
metatsv = '~{metatsv}'
prefix = '~{prefix}'

epiToGisaid = dict()
with open(metatsv, 'r') as m:
    m.readline()
    for line in m:
        strain = line.strip().split('\t')[0]
        epiToGisaid[strain.split('|')[1]] = strain

foi={
    'assembly_fasta':'',
    'percent_reference_coverage':'',
    'pango_lineage':'',
    'nextclade_clade':'',
    'gisaid_accession':'',
    'county':'',
    'collection_date':'',
    'paui':''
}
noPassIds = []
gatherfastas = []
outrows = []
seen = set()
for table_name in (tnames.split(',')):
  table = json.loads(fapi.get_entities(workspace_project, workspace_name, table_name).text)
  for row in table:
    addFlag = False
    rdict = dict([('usherID', prefix+row['name']), ('name',row['name'])] + [(k, r) for k, r in foi.items()] +
              [(k,r) for k, r in row['attributes'].items() if k in foi.keys()])
    if rdict['assembly_fasta']=='':
        noPassIds.append("{}\tno fasta file\n".format(rdict['name']))
    elif re.search(r"EMPTY", rdict['assembly_fasta']):
        noPassIds.append("{}\tfasta filename indicates EMPTY\n".format(rdict['name']))
    elif float(rdict['percent_reference_coverage']) < 90:
        noPassIds.append("{}\tcoverage {} does not pass 90% threshold\n".format(rdict['name'], rdict['percent_reference_coverage']))
    elif rdict['gisaid_accession'] == '':
        addFlag = True
        gatherfastas.append(rdict['assembly_fasta'])
    else:
        addFlag = True
        try:
           rdict['usherID'] = epiToGisaid[rdict['gisaid_accession']] 
        except KeyError:
           gatherfastas.append(rdict['assembly_fasta'])
    if addFlag == True and not row['name'] in seen:
        [rdict.pop(key) for key in ['assembly_fasta', 'percent_reference_coverage']]
        rdict = {k:(' ' if v=='' else v) for (k,v) in rdict.items()} # add whitespace in empty fields
        outrows.append(rdict)
    seen.add(row['name'])
# print full metadata file; contains samples already in the tree as well as new ones
with open("samplemeta.tsv", 'wt') as outf:
    writer = csv.DictWriter(outf, outrows[0].keys(), delimiter='\t', dialect=csv.unix_dialect, quoting=csv.QUOTE_MINIMAL)
    writer.writeheader()
    writer.writerows(outrows)
with open("failQC.tsv", 'wt') as outf:
    outf.writelines(noPassIds)
# fasta files for samples not already in the tree
with open("fafiles.txt", 'w') as outf:
    outf.write('\n'.join(gatherfastas))

CODE
    >>>
    runtime {
      docker: "schaluvadi/pathogen-genomic-surveillance:api-wdl"
      memory: "16 GB"
      cpu: 4
      disks: "local-disk 10 SSD"
    }
    output{
        File gatherfastas = "fafiles.txt"
        File noPassIds= "failQC.tsv"
        File sample_meta = "samplemeta.tsv"
    }
}

task gcs_copy_fafiles {
  meta { description: "Copied from https://github.com/broadinstitute/viral-pipelines/blob/master/pipes/WDL/tasks/tasks_terra.wdl#L3-L30" }
  input {
    File falist
    String  prefix
    Int num_threads = 16
    Int mem_size = 16
    Int diskSizeGB = 30
  }
  command <<<
    set -e
    mkdir download_dir
    cat ~{falist} | gsutil -m cp -I ./download_dir
    awk -F "/" '{print "download_dir/"$NF}' ~{falist} > fafiles
    split -l 500 fafiles fasplit
    for fname in $(ls fasplit*); do
        cat $(cat $fname) > combi.$fname &
    done
    wait
    for combi in $(ls combi.fasplit*); do
        cat $combi >> combined.fa
    done
    sed -i -E 's/>D([0-9])/>D-\1/' combined.fa
    sed -i 's/_redo//' combined.fa
    sed -i "s/>/>~{prefix}/" combined.fa

  >>>
  output {
    File combined_fasta = "combined.fa"
  }
  runtime {
    docker: "quay.io/broadinstitute/viral-baseimage:0.1.20"
    cpu: num_threads
    memory: mem_size +" GB"
    disks: "local-disk " + diskSizeGB + " SSD"
  }
}


# Get the SARS-CoV-2 reference off the usher docker container while we're at it
task getProblemVcf {
    meta { description: "Retrieves a regularly updated VCF with problematic sites in the SARS-CoV-2 sequence" }
    command {
        wget -O "problem.vcf" "https://raw.githubusercontent.com/W-L/ProblematicSites_SARS-CoV2/master/problematic_sites_sarsCov2.vcf"
        cp "/HOME/usher/test/NC_045512v2.fa" "NC_045512v2.fa"
    }
    output {
        File problem_vcf = "problem.vcf"
        File ref_fasta = "NC_045512v2.fa"
    }
    runtime {
        docker: "yatisht/usher:latest"
    }
}

task faToVcf {
    meta { description: "uses UShER's faToVcf to turn a mafft multifasta alignment into VCF format" }
    input {
        File fasta
        File problem_vcf
        Int num_threads = 16
        Int mem_size = 500
        Int diskSizeGB = 30
    }
    command {
        # the reference sequence must be first
        faToVcf -maskSites=${problem_vcf} ${fasta} "sample.vcf"
    }
    output {
        File sample_vcf = "sample.vcf"
    }
    runtime {
        docker: "yatisht/usher:latest"
        cpu: num_threads
        memory: mem_size +" GB"
        disks: "local-disk " + diskSizeGB + " SSD"
    }
}

task usherAddSamples {
    meta { description: "Runs UShER to create a new tree from an existing tree and a vcf file of input samples" }
    input {
        File vcf
        File protobuf
        Int mem_size = 30
        Int num_threads = 32
        Int diskSizeGB = 30
    }
    command {
        usher -i ${protobuf} -T ${num_threads} -v ${vcf} -o "new_tree.pb"
    }
    output {
        File new_tree = "new_tree.pb"
    }
    runtime { 
        docker: "yatisht/usher:latest" 
        cpu: num_threads
        memory: mem_size +" GB"
        disks: "local-disk " + diskSizeGB + " SSD"
    } 
}

# based on https://raw.githubusercontent.com/broadinstitute/viral-pipelines/master/pipes/WDL/tasks/tasks_nextstrain.wdl
task mafft_align {
    meta {
        description: "Align multiple sequences from FASTA. Only appropriate for closely related (within 99% nucleotide conservation) genomes. See https://mafft.cbrc.jp/alignment/software/closelyrelatedviralgenomes.html"
    }
    input {
        File     sequences
        File     ref_fasta
        String   docker = "quay.io/broadinstitute/viral-phylo:2.1.19.1"
        Int      mem_size = 500
        Int      cpus = 64
    }
    command {
        set -e

        GENOMES="~{sequences}"

        # mafft align to reference in "closely related" mode
        mafft --auto --thread ~{cpus} --keeplength --addfragments $GENOMES ~{ref_fasta} > aligned.fasta

        # profiling and stats
        cat /proc/uptime | cut -f 1 -d ' ' > UPTIME_SEC
        cat /proc/loadavg > CPU_LOAD
        cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes > MEM_BYTES
    }
    runtime {
        docker: docker
        memory: mem_size + " GB"
        cpu :   cpus
        disks:  "local-disk 750 LOCAL"
        preemptible: 0
        dx_instance_type: "mem3_ssd1_v2_x36"
    }
    output {
        File   aligned_sequences = "aligned.fasta"
        Int    max_ram_gb        = ceil(read_float("MEM_BYTES")/1000000000)
        Int    runtime_sec       = ceil(read_float("UPTIME_SEC"))
        String cpu_load          = read_string("CPU_LOAD")
    }
}


task Extract {
    meta { description: "matUtils extracts all samples into (shared) subtrees; output table with metadata links to visualisation via nextstrain" }
    input {
	File tree_pb
        File public_meta
        File samples_meta
        String prefix
        Int treesize
        String public_json_bucket
        Int num_threads = 32
        Int mem_size = 128
        Int diskSizeGB = 10
    }
    String nextstr = "https://nextstrain.org/fetch/storage.googleapis.com"

    command <<<
        cut -f1 ~{samples_meta} | tail -n +2 > sample.ids
        cut -f 1,8 ~{samples_meta} | tail -n +2 > name_and_paui.tsv
        matUtils extract -M ~{public_meta},~{samples_meta} -i ~{tree_pb} -j ~{prefix} -s sample.ids -N ~{treesize}
        # we can't have double slashes in URLs
        bucket=$(echo ~{public_json_bucket} | sed 's/\///')
        # turn the subtree file into a list of URLs in a html table
        outdir=$(date +~{prefix}_%m_%d_%Y)
        echo -n "${bucket}/$outdir" > resultbucket.txt
        urlstart="~{nextstr}/${bucket}/${outdir}/"
python3 - "$urlstart" <<CODE
import sys
import csv
urlstart=sys.argv[1]
name_dict = dict()

with open('name_and_paui.tsv', newline='') as csvfile:
  tsvfile = csv.reader(csvfile, delimiter = '\t')
  for rows in tsvfile:
    name_dict[rows[0]] = rows[1]

with open('subtree-assignments.tsv', 'r') as f, open('paui2url.tsv', 'wt') as out_file, open('samples_subtrees.html', 'w') as o:
  tsv_writer = csv.writer(out_file, delimiter='\t')
  o.write('<html><body>')
  o.write('<table border=2 cellspacing=0 cellpadding=4>' + "\n")
  for line in f:
    items = line.split("\t")
    if items[1].endswith('json'):
        o.write('<tr>' + "\n")
        items[1] = "<a href=\"{0}{1}?s={2}\">{1}</a>".format(urlstart, items[1].split('/')[-1], items[0].replace('|','%7C'))
        urljson = items[1]
        sample = items[0]
        id = name_dict.get(sample, 'NONE')
        tsv_writer.writerow([sample, id, urljson])
    else:
        o.write('<tr bgcolor="#FAD7A0">' + "\n")
    for item in items:
        o.write("<td>%s</td>" % item)
    o.write('</tr>')
  o.write('</table></body></html>')

CODE
    >>>	
    output {
        File out_html = "samples_subtrees.html"
        File out_tsv = "subtree-assignments.tsv"
        File specimen_mapped_to_paui = "name_and_paui.tsv"
        File paui_mapped_to_tree = "paui2url.tsv"
        Array[File] subtree_jsons = glob("*subtree*")
        String bucket = read_string("resultbucket.txt")
    }
    runtime {
        docker: "yatisht/usher:latest"
        cpu: num_threads
        memory: mem_size +" GB"
        disks: "local-disk " + diskSizeGB + " SSD"
    }   

}


task gcs_copy {
  meta { description: "Copied from https://github.com/broadinstitute/viral-pipelines/blob/master/pipes/WDL/tasks/tasks_terra.wdl#L3-L30" }
  input {
    Array[File] infiles
    String      gcs_uri_prefix
  }
  parameter_meta {
    infiles: {
      description: "Input files",
      localization_optional: true,
      stream: true
    }
  }
  command {
    set -e
    gsutil -m cp ~{sep=' ' infiles} gs://~{gcs_uri_prefix}
  }
  output {
    File logs = stdout()
  }
  runtime {
    docker: "quay.io/broadinstitute/viral-baseimage:0.1.20"
    memory: "1 GB"
    cpu: 4
  }
}

