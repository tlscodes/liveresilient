/^SF:/{file=$0; sub("SF:","",file); hit=0; total=0}
/^DA:/{split($0,a,","); total++; if(a[2]+0>0) hit++}
/^end_of_record/{printf "%-90s %d/%d = %.1f%%\n", file, hit, total, (total>0?100.0*hit/total:0)}
