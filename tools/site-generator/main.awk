BEGIN {
    init_runtime();
    rngA=(ENVIRON["RW_SITE_SEED_A"]+0)%2147483562+1;
    rngB=(ENVIRON["RW_SITE_SEED_B"]+0)%2147483398+1;
    init_design(); baseline_serial=serial;
    audit=ENVIRON["RW_SITE_AUDIT"]+0;
    count=audit?audit:1;
    for(generation=0;generation<count;generation++) {
        instance=newobj("dict");
        m___init__(instance,rngA);
        result=m_generate(instance);
        html=text(get(result,box("html")));
        sections=check_html(html);
        dna=get(result,box("dna"));
        if(!audit) {
            printf "%s",html;
            if(ENVIRON["RW_SITE_DNA_FILE"]!="") {
                print jsonval(dna) > ENVIRON["RW_SITE_DNA_FILE"];
                close(ENVIRON["RW_SITE_DNA_FILE"]);
            }
        } else {
            sig=text(get(dna,box("signature"))); signatures[sig]++;
            hero=text(get(get(dna,box("hero")),box("family")));heroes[hero]++;
            art=text(get(dna,box("art_direction")));arts[art]++;
            order=jsonval(get(get(dna,box("sections")),box("sequence")));orders[order]++;
            footer=text(get(get(dna,box("footer")),box("family")));footers[footer]++;
            # Discard per-page objects; constants and counters survive.
            for(obj=baseline_serial+1;obj<=serial;obj++) {
                handle="\034" obj;
                for(j=0;j<N[handle];j++){delete V[handle,K[handle,j]];delete K[handle,j]}
                delete N[handle];delete T[handle];
            }
            serial=baseline_serial;
        }
    }
    if(audit) {
        for(k in signatures)unique++;for(k in heroes)hero_count++;
        for(k in arts)art_count++;for(k in orders)order_count++;for(k in footers)footer_count++;
        passed=unique==count && order_count>=count*.9 && (count<100 || (hero_count>=12 && art_count>=8 && footer_count==6));
        printf "{\"generations\":%d,\"unique_signatures\":%d,\"unique_section_orders\":%d,\"hero_families_seen\":%d,\"art_directions_seen\":%d,\"footer_families_seen\":%d,\"passed\":%s}\n",count,unique,order_count,hero_count,art_count,footer_count,passed?"true":"false";
        exit !passed;
    }
}
