# Structural checks before publishing a generated page. No external HTML tools.
function attr(tag,name, pattern,s){pattern="[[:space:]]" name "=[\"']";if(!match(tag,pattern))return "";s=substr(tag,RSTART+RLENGTH);return substr(s,1,index(s,substr(tag,RSTART+RLENGTH-1,1))-1)}
function check_html(html, rest,tag,name,closing,stack,depth,i,id,target,sections,h1,styles,mains,heads,bodies,roots){
    for(i in IDS)delete IDS[i];for(i in LINKS)delete LINKS[i];
    rest=html;depth=sections=h1=styles=mains=heads=bodies=roots=0;
    if(substr(tolower(html),1,15)!="<!doctype html>")fatal("missing HTML5 doctype");
    if(html~/fonts\.googleapis\.com|fonts\.gstatic\.com/)fatal("remote fonts");
    while(match(rest,/<[^>]*>/)){
        tag=substr(rest,RSTART,RLENGTH);rest=substr(rest,RSTART+RLENGTH);
        if(tag~/^<!/)continue;
        closing=tag~/^<\//;name=tolower(tag);sub(/^<\/?/,"",name);sub(/[[:space:]\/\>].*$/,"",name);
        if(name=="script" || tag~/[[:space:]]on[a-z]+[[:space:]]*=/ || tolower(tag)~/javascript:/)fatal("active content");
        if(closing){if(depth<1 || stack[depth]!=name)fatal("unbalanced closing tag " name);depth--;continue}
        if(name=="html"){roots++;if(attr(tag,"lang")!="ru")fatal("missing Russian lang")}
        if(name=="head")heads++;if(name=="body")bodies++;if(name=="main")mains++;
        if(name=="section")sections++;if(name=="h1")h1++;
        id=attr(tag,"id");if(id!=""){if(id in IDS)fatal("duplicate id " id);IDS[id]=1}
        target=attr(tag,"href");if(substr(target,1,1)=="#")LINKS[substr(target,2)]=1;
        if(name=="style"){
            styles++;
            if(!match(rest,/<\/style>/))fatal("unclosed style");
            rest=substr(rest,RSTART+RLENGTH);continue;
        }
        if(tag~/\/>$/ || name~/^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/)continue;
        stack[++depth]=name;
    }
    if(depth || roots!=1 || heads!=1 || bodies!=1 || mains!=1 || h1!=1 || styles!=1 || sections<8 || sections>16)fatal("invalid document structure");
    for(target in LINKS)if(target!="" && !(target in IDS))fatal("missing anchor " target);
    if(html~/<span>(DNA|SYSTEM|MODE|GRID)<\/span>/)fatal("visible generator diagnostics");
    return sections;
}
