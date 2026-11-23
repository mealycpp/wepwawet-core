#!/usr/bin/env python3
"""Sending-window overlap of the two nodes in the v8 duplex runs (first/last successful sign per node, CLOCK_MONOTONIC
of each board; the two boards booted within ~1 s of each other, cross-board alignment good to about 2 s)."""
import csv,glob
B='05_RESULTS/board_logs'
for tag in ['duplexv8','duplexv8b','duplexv8c','duplexv8cert']:
    w={}
    for h in ['aup1','aup2']:
        d=glob.glob(f'{B}/{h}/wepwawet-core/logs/mission_runs/*_{tag}')[0]
        S=[float(r[0])/1e6 for r in csv.reader(open(d+'/hw_stats_run.csv')) if len(r)>=12 and r[1]=='sign' and r[3]=='0']
        f=open(d+'/fsw.log',errors='replace').read()
        w[h]=(min(S),max(S),len(S),f.count('verdict=ACCEPT'),f.count('verdict=REJECT'),f.count('peer exchange failed'),f.count('Assert:'))
    a,b=w['aup1'],w['aup2']
    print(f"{tag}: node1 window {a[1]-a[0]:.1f} s signed {a[2]} accepted_here {a[3]} rejected {a[4]} exchange_failed {a[5]} asserts {a[6]} | "
          f"node2 window {b[1]-b[0]:.1f} s signed {b[2]} accepted_here {b[3]} rejected {b[4]} exchange_failed {b[5]} asserts {b[6]} | "
          f"node2 start minus node1 start {b[0]-a[0]:+.1f} s, overlap {min(a[1],b[1])-max(a[0],b[0]):.1f} s")
