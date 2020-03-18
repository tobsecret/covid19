#!/usr/bin/env python

import os
import sys
import argparse

def parse_args(args=None):
    Description = 'Reformat nf-core/covid19 samplesheet file and check its contents.'
    Epilog = """Example usage: python check_samplesheet.py <FILE_IN> <FILE_OUT>"""

    parser = argparse.ArgumentParser(description=Description, epilog=Epilog)
    parser.add_argument('FILE_IN', help="Input samplesheet file.")
    parser.add_argument('FILE_OUT', help="Output samplesheet file.")

    return parser.parse_args(args)


def print_error(error,line):
    print("ERROR: Please check samplesheet -> {}\nLine: '{}'".format(error,line.strip()))


def check_samplesheet(FileIn,FileOut):
    HEADER = ['sample', 'short_fastq_1', 'short_fastq_2', 'long_fastq']

    ## CHECK HEADER
    fin = open(FileIn,'r')
    header = fin.readline().strip().split(',')
    if header != HEADER:
        print("ERROR: Please check samplesheet header -> {} != {}".format(','.join(header),','.join(HEADER)))
        sys.exit(1)

    outLines = []
    while True:
        line = fin.readline()
        if line:
            lspl = [x.strip() for x in line.strip().split(',')]

            ## CHECK VALID NUMBER OF COLUMNS PER SAMPLE
            numCols = len([x for x in lspl if x])
            if numCols not in [2,3]:
                print_error("Please specify 'sample' entry along with either 'short_fastq_1'/'short_fastq_2' or with 'long_fastq'!",line)
                sys.exit(1)

            ## CHECK SAMPLE ID ENTRIES
            sample,fastQFiles = lspl[0],lspl[1:]
            if sample:
                if sample.find(' ') != -1:
                    print_error("Sample entry contains spaces!",line)
                    sys.exit(1)
            else:
                print_error("Sample entry has not been specified!",line)
                sys.exit(1)

            ## CHECK FASTQ FILE EXTENSION
            for fastq in fastQFiles:
                if fastq:
                    if fastq.find(' ') != -1:
                        print_error("FastQ file contains spaces!",line)
                        sys.exit(1)
                    if fastq[-9:] != '.fastq.gz' and fastq[-6:] != '.fq.gz':
                        print_error("FastQ file does not have extension '.fastq.gz' or '.fq.gz'!",line)
                        sys.exit(1)

            ## AUTO-DETECT ILLUMINA/NANOPORE
            single_end = '0'
            long_reads = '0'
            short_fastq_1,short_fastq_2,long_fastq = fastQFiles
            print fastQFiles
            if short_fastq_1 and short_fastq_2:
                pass
            elif short_fastq_1 and not short_fastq_2:
                single_end = '1'
            elif not short_fastq_1 and not short_fastq_2 and long_fastq:
                long_reads = '1'
            else:
                print_error("Please specify 'sample' entry along with either 'short_fastq_1'/'short_fastq_2' or with 'long_fastq'!",line)

            if long_reads == '0':
                outLines.append([sample,short_fastq_1,short_fastq_2,single_end,long_reads])
            else:
                outLines.append([sample,long_fastq,'',single_end,long_reads])
        else:
            fin.close()
            break

    ## WRITE TO FILE
    fout = open(FileOut,'w')
    fout.write(','.join(['sample', 'fastq_1', 'fastq_2', 'single_end', 'long_reads']) + '\n')
    for line in outLines:
        fout.write(','.join(line) + '\n')
    fout.close()


def main(args=None):
    args = parse_args(args)
    check_samplesheet(args.FILE_IN,args.FILE_OUT)


if __name__ == '__main__':
    sys.exit(main())
