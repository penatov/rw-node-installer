# POSIX awk support for the mechanically ported design functions.
# LC_ALL=C is deliberate: UTF-8 operations below work equally in mawk/gawk.
# Strings are tagged; collections use handles, so strings like "2026" are
# never accidentally added as numbers. None is distinct from an empty string.
function box(s) { return "\035" s }
function text(v) { return substr(v,1,1)=="\035" ? substr(v,2) : v==NONE ? "None" : sprintf("%.15g",v) }
function numeric(v) { return substr(v,1,1)=="\035" ? substr(v,2)+0 : v+0 }
function stringval(v) { return box(text(v)) }
function newobj(type, id) { id="\034" ++serial; T[id]=type; N[id]=0; return id }
function isobj(v) { return substr(v,1,1)=="\034" }
function truth(v) { return v!=NONE && (isobj(v) ? N[v]>0 : substr(v,1,1)=="\035" ? length(substr(v,2))>0 : v!=0) }
function keyval(k) { return substr(k,1,1)=="\035" ? substr(k,2) : k }
function put(o,k,v, key) {
    key=keyval(k);
    if(T[o]!="dict" && key<0) key+=N[o];
    if(!((o SUBSEP key) in V)) { K[o,N[o]]=key; N[o]++ }
    V[o,key]=v; return v;
}
function get(o,k, key) {
    if(substr(o,1,1)=="\035") return box(ucharat(text(o),k));
    key=keyval(k); if(T[o]!="dict" && key<0) key+=N[o];
    if(!((o SUBSEP key) in V)) { fatal("missing design value: " key " (" T[o] ", keys=" objectkeys(o) ")"); }
    return V[o,key];
}
function objectkeys(o, i,s){s="";for(i=0;i<N[o];i++)s=s (i?",":"") K[o,i];return s}
function push(o,v) { if(T[o]=="set" && contains(o,v)) return NONE; put(o,N[o],v); return NONE }
function extend(o,v, i) { for(i=0;i<N[v];i++) push(o,get(v,i)); return o }
function lengthval(v) { return isobj(v) ? N[v] : ulen(text(v)) }
function iterable(v, o,i) {
    if(isobj(v) && T[v]!="dict") return v;
    o=newobj("list");
    if(T[v]=="dict") { for(i=0;i<N[v];i++) push(o,box(K[v,i])); }
    else { for(i=0;i<ulen(text(v));i++) push(o,box(ucharat(text(v),i))); }
    return o;
}
function contains(o,v, i) {
    if(T[o]=="dict") return ((o SUBSEP keyval(v)) in V);
    if(isobj(o)) { for(i=0;i<N[o];i++) if(V[o,i]==v) return 1; return 0 }
    return index(text(o),text(v))>0;
}
function copylist(v, o) { o=newobj("list"); if(v=="") return o; return extend(o,iterable(v)) }
function copydict(v, o,i,k) { o=newobj("dict"); for(i=0;i<N[v];i++){ k=K[v,i]; put(o,box(k),V[v,k]) } return o }
function makeset(v, o,i) { o=newobj("set"); if(v=="") return o; v=iterable(v); for(i=0;i<N[v];i++) push(o,get(v,i)); return o }
function sliceval(v,start,end,step, size,o,i) {
    size=lengthval(v); if(step==NONE) step=1;
    if(start==NONE) start=step>0?0:size-1; else if(start<0) start+=size;
    if(end==NONE) end=step>0?size:-1; else if(end<0) end+=size;
    start=step>0?max2(0,min2(size,start)):min2(size-1,start);
    end=step>0?max2(0,min2(size,end)):max2(-1,end);
    o=isobj(v)?newobj("list"):box("");
    for(i=start;step>0?i<end:i>end;i+=step) {
        if(isobj(v)) push(o,get(v,i)); else o=box(text(o) text(get(v,i)));
    }
    return o;
}
function removeval(v,k, i) { if(k<0)k+=N[v]; for(i=k;i<N[v]-1;i++)V[v,i]=V[v,i+1]; delete V[v,N[v]-1]; delete K[v,N[v]-1]; N[v]--; return NONE }
function insertval(v,k,x, i) { if(k<0)k=max2(0,N[v]+k); k=min2(k,N[v]); for(i=N[v];i>k;i--){V[v,i]=V[v,i-1];K[v,i]=i} V[v,k]=x;K[v,k]=k;N[v]++;return NONE }
function reverseval(v, i,x) { for(i=0;i<int(N[v]/2);i++){x=V[v,i];V[v,i]=V[v,N[v]-1-i];V[v,N[v]-1-i]=x}return NONE }
function opval(op,a,b, o,i,z) {
    if(op=="add") {
        if(isobj(a)) {o=copylist(a);return extend(o,b)}
        if(substr(a,1,1)=="\035")return box(text(a) text(b));
        return a+b;
    }
    if(op=="mul") {
        if(substr(b,1,1)=="\035" || isobj(b)){z=a;a=b;b=z}
        if(substr(a,1,1)=="\035"){o="";for(i=0;i<b;i++)o=o text(a);return box(o)}
        if(isobj(a)){o=newobj("list");for(i=0;i<b;i++)extend(o,a);return o}
        return a*b;
    }
    if(op=="sub")return a-b;
    if(op=="div")return a/b;
    if(op=="floor")return floorval(a/b);
    if(op=="mod")return a-b*floorval(a/b);
    if(op=="pow")return a^b;
    fatal("unsupported arithmetic " op);
}
function min2(a,b){return a<b?a:b}
function max2(a,b){return a>b?a:b}
function absolute(a){return a<0?-a:a}
function floorval(a, n){n=int(a);return n>a?n-1:n}
function ceilval(a){return -floorval(-a)}
function roundval(a,d){return sprintf("%.*f",d,a)+0}
function extreme(v,maximum, i,r,x){if(N[v]==1 && isobj(get(v,0)))v=get(v,0);r=get(v,0);for(i=1;i<N[v];i++){x=get(v,i);if(maximum?x>r:x<r)r=x}return r}
function sumlist(v, i,s){s=0;for(i=0;i<N[v];i++)s+=get(v,i);return s}
function alllist(v, i){for(i=0;i<N[v];i++)if(!truth(get(v,i)))return 0;return 1}
function rangeval(a,b,step, v,i){v=newobj("list");for(i=a;step>0?i<b:i>b;i+=step)push(v,i);return v}
function enumerateval(v,start, out,i,p){out=newobj("list");v=iterable(v);for(i=0;i<N[v];i++){p=newobj("tuple");push(p,i+start);push(p,get(v,i));push(out,p)}return out}
function compareval(a,b, i,c){if(isobj(a) && isobj(b)){for(i=0;i<min2(N[a],N[b]);i++){c=compareval(get(a,i),get(b,i));if(c)return c}return N[a]-N[b]}return a==b?0:a<b?-1:1}
function sortlist(v, out,i,j,x){out=copylist(v);for(i=1;i<N[out];i++){x=V[out,i];j=i-1;while(j>=0 && compareval(V[out,j],x)>0){V[out,j+1]=V[out,j];j--}V[out,j+1]=x}return out}
function istype(v,type){
    if(type=="str")return substr(v,1,1)=="\035";
    if(type=="tuple" || type=="list")return T[v]==type;
    if(type=="Mapping")return T[v]=="dict";
    if(type=="float")return !isobj(v) && substr(v,1,1)!="\035" && v!=int(v);
    if(type=="(int, float)")return !isobj(v) && substr(v,1,1)!="\035" && v!=NONE;
    fatal("unsupported type test " type);
}
function rng_random( a,b) { rngA=(rngA*40014)%2147483563; rngB=(rngB*40692)%2147483399; a=rngA-rngB; if(a<1)a+=2147483562;return a/2147483563 }
function rng_randint(lo,hi){return lo+int(rng_random()*(hi-lo+1))}
function rng_uniform(lo,hi){return lo+(hi-lo)*rng_random()}
function rng_choice(v){return get(v,rng_randint(0,N[v]-1))}
function rng_shuffle(v, i,j,x){for(i=N[v]-1;i>0;i--){j=rng_randint(0,i);x=V[v,i];V[v,i]=V[v,j];V[v,j]=x}return NONE}
function rng_sample(v,k, pool,out,i,j){pool=copylist(v);out=newobj("list");for(i=0;i<k;i++){j=rng_randint(0,N[pool]-1);push(out,get(pool,j));removeval(pool,j)}return out}
function g_weighted_pick(rng,options, weights,values,i,x,w,total,p){
    weights=newobj("list");values=newobj("list");total=0;
    for(i=0;i<N[options];i++){x=get(options,i);w=1;if(T[x]=="tuple" && N[x]==2){w=get(x,1);x=get(x,0)}push(values,x);push(weights,w);total+=w}
    p=rng_random()*total;
    for(i=0;i<N[values];i++){p-=get(weights,i);if(p<0)return get(values,i)}return get(values,N[values]-1);
}
function g_chance(rng,p){return rng_random()<max2(0,min2(1,p))}
function g_clamp(v,lo,hi){return max2(lo,min2(hi,v))}
function utfsize(s, c){c=ORD[substr(s,1,1)];return c<128?1:c<224?2:c<240?3:4}
function ulen(s, i,n){n=0;for(i=1;i<=length(s);){i+=utfsize(substr(s,i));n++}return n}
function ucharat(s,pos, i,n){if(pos<0)pos+=ulen(s);n=0;for(i=1;i<=length(s);){if(n==pos)return substr(s,i,utfsize(substr(s,i)));i+=utfsize(substr(s,i));n++}return ""}
function caseval(s,upper, out,i,c){out="";for(i=1;i<=length(s);){c=substr(s,i,utfsize(substr(s,i)));out=out (upper?(c in UPPER?UPPER[c]:length(c)==1?toupper(c):c):(c in LOWER?LOWER[c]:length(c)==1?tolower(c):c));i+=length(c)}return out}
function stripval(s,chars, c){if(chars==NONE){sub(/^[ \t\r\n]+/,"",s);sub(/[ \t\r\n]+$/,"",s);return s}chars=text(chars);while(length(s)){c=ucharat(s,0);if(!index(chars,c))break;s=substr(s,length(c)+1)}while(length(s)){c=ucharat(s,-1);if(!index(chars,c))break;s=substr(s,1,length(s)-length(c))}return s}
function replaceval(s,old,repl,count, out,p,n){out="";n=0;while((p=index(s,old)) && (count==NONE || n<count)){out=out substr(s,1,p-1) repl;s=substr(s,p+length(old));n++}return out s}
function splitwords(s,sep, out,p,part){out=newobj("list");if(sep==NONE){s=stripval(s,NONE);while(match(s,/[^ \t\r\n]+/)){push(out,box(substr(s,RSTART,RLENGTH)));s=substr(s,RSTART+RLENGTH)}}else{sep=text(sep);while((p=index(s,sep))){push(out,box(substr(s,1,p-1)));s=substr(s,p+length(sep))}push(out,box(s))}return out}
function methodval(v,name,argc,a,b,c, out,i,k,s){
    if(name=="setdefault"){k=keyval(a);if(!((v SUBSEP k) in V))put(v,a,b);return V[v,k]}
    if(name=="get"){k=keyval(a);return ((v SUBSEP k) in V)?V[v,k]:argc>1?b:NONE}
    if(name=="append" || name=="add")return push(v,a);
    if(name=="insert")return insertval(v,a,b);
    if(name=="reverse")return reverseval(v);
    if(name=="items"){out=newobj("list");for(i=0;i<N[v];i++){k=K[v,i];s=newobj("tuple");push(s,box(k));push(s,V[v,k]);push(out,s)}return out}
    if(name=="join"){out="";a=iterable(a);for(i=0;i<N[a];i++)out=out (i?text(v):"") text(get(a,i));return box(out)}
    s=text(v);
    if(name=="upper")return box(caseval(s,1));
    if(name=="lower")return box(caseval(s,0));
    if(name=="capitalize")return box(caseval(ucharat(s,0),1) caseval(substr(s,length(ucharat(s,0))+1),0));
    if(name=="strip")return box(stripval(s,argc?a:NONE));
    if(name=="split")return splitwords(s,argc?a:NONE);
    if(name=="replace")return box(replaceval(s,text(a),text(b),argc>2?c:NONE));
    if(name=="startswith")return index(s,text(a))==1;
    fatal("unsupported design operation " name);
}
function wordlist(v, s,out,w,i,c){s=text(v);out=newobj("list");w="";for(i=1;i<=length(s);){c=substr(s,i,utfsize(substr(s,i)));if(c~/^[A-Za-z0-9]$/ || c in UPPER || c in LOWER)w=w c;else if(w!=""){push(out,box(w));w=""}i+=length(c)}if(w!="")push(out,box(w));return out}
function headline_clauses(v, s,out,piece){s=text(v);out=newobj("list");while(match(s,/[.!?][ \t]+|[ \t]+—[ \t]+|:[ \t]+/)){piece=substr(s,1,RSTART-1);if(substr(s,RSTART,1)~/[.!?]/)piece=piece substr(s,RSTART,1);push(out,box(piece));s=substr(s,RSTART+RLENGTH)}push(out,box(s));return out}
function g_slugify(v, s,out,i,c){s=caseval(text(v),0);s=replaceval(s,"ё","ё",NONE);s=replaceval(s,"й","й",NONE);out="";for(i=1;i<=length(s);){c=substr(s,i,utfsize(substr(s,i)));if(c~/^[a-z0-9]$/ || c in UPPER)out=out c;else if(substr(out,length(out),1)!="-")out=out "-";i+=length(c)}sub(/^-/,"",out);sub(/-$/,"",out);return box(out==""?"section":out)}
function g_cap_first(v, s,c){s=text(v);c=ucharat(s,0);return box(caseval(c,1) substr(s,length(c)+1))}
function g_esc(v,quote_attr, s){s=text(v);s=replaceval(s,"&","&amp;",NONE);s=replaceval(s,"<","&lt;",NONE);s=replaceval(s,">","&gt;",NONE);if(quote_attr){s=replaceval(s,"\"","&quot;",NONE);s=replaceval(s,"'","&#x27;",NONE)}return box(s)}
function formatval(v,spec, f,s,i,out,sign){f=text(spec);if(f=="")return box(text(v));if(f==","){s=sprintf("%.0f",v);sign="";if(substr(s,1,1)=="-"){sign="-";s=substr(s,2)}out="";while(length(s)>3){out="," substr(s,length(s)-2) out;s=substr(s,1,length(s)-3)}return box(sign s out)}return box(sprintf("%" f,v))}
function g_hsl_css(h,s,l,alpha, out){out=sprintf("hsl(%.1f %.1f%% %.1f%%",opval("mod",h,360),g_clamp(s,0,100),g_clamp(l,0,100));if(alpha!=NONE)out=out sprintf(" / %.3f",g_clamp(alpha,0,1));return box(out ")")}
function hue(p,q,t){if(t<0)t++;if(t>1)t--;if(t<1/6)return p+(q-p)*6*t;if(t<1/2)return q;if(t<2/3)return p+(q-p)*(2/3-t)*6;return p}
function g_hsl_to_rgb(h,s,l, q,p,out){h=opval("mod",h,360)/360;s/=100;l/=100;out=newobj("tuple");if(s==0){push(out,l);push(out,l);push(out,l);return out}q=l<0.5?l*(1+s):l+s-l*s;p=2*l-q;push(out,hue(p,q,h+1/3));push(out,hue(p,q,h));push(out,hue(p,q,h-1/3));return out}
function linear(c){return c<=0.04045?c/12.92:((c+0.055)/1.055)^2.4}
function g_relative_luminance(v){return .2126*linear(get(v,0))+.7152*linear(get(v,1))+.0722*linear(get(v,2))}
function g_contrast_ratio(a,b,la,lb){la=g_relative_luminance(a);lb=g_relative_luminance(b);return (max2(la,lb)+.05)/(min2(la,lb)+.05)}
function g_pick_text_lightness(h,s,l, bg,values,n,a,i,c,best,primary,muted,target,distance,out){
    bg=g_hsl_to_rgb(h,s,l);n=split("4 7 10 13 16 20 24 28 32 36 40 98 96 94 92 90 86 82 78 74 70 66",a," ");best=-1;
    for(i=1;i<=n;i++){c=g_contrast_ratio(bg,g_hsl_to_rgb(h,min2(s,12),a[i]));if(c>best){best=c;primary=a[i]+0}}
    target=primary+(primary<l?26:-26);distance=1e9;muted=primary;
    for(i=18;i<86;i++){c=g_contrast_ratio(bg,g_hsl_to_rgb(h,min2(s,15),i));if(c>=4.55 && absolute(i-target)<distance){muted=i;distance=absolute(i-target)}}
    out=newobj("tuple");push(out,primary);push(out,muted);return out;
}
function g_svg_data_uri(v, s,out,i,c){s=stripval(text(v),NONE);gsub(/>[ \t\r\n]+</,"><",s);out="data:image/svg+xml,";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c~/^[A-Za-z0-9_.~()-]$/ || index("/,:;+='\"",c))out=out c;else out=out sprintf("%%%02X",ORD[c])}return box(out)}
function g_chunks(v,size, out,i){out=newobj("list");for(i=0;i<N[v];i+=size)push(out,sliceval(v,i,i+size,NONE));return out}
function flatten_into(v,prefix,out, i,k,p,x,allmaps){
    if(T[v]=="dict"){for(i=0;i<N[v];i++){k=K[v,i];if(k=="parameter_groups")continue;p=box((text(prefix)!=""?text(prefix) ".":"") k);flatten_into(V[v,k],p,out)}}
    else if(T[v]=="list" && N[v]>0){allmaps=1;for(i=0;i<N[v];i++)if(T[get(v,i)]!="dict")allmaps=0;if(allmaps){for(i=0;i<N[v];i++)flatten_into(get(v,i),box(text(prefix) "[" i "]"),out)}else put(out,prefix,v)}
    else put(out,prefix,v);return NONE;
}
function jsonquote(s, out,i,c){out="\"";for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c=="\"")out=out "\\\"";else if(c=="\\")out=out "\\\\";else if(c=="\n")out=out "\\n";else if(c=="\r")out=out "\\r";else if(c=="\t")out=out "\\t";else if(ORD[c]<32)out=out sprintf("\\u%04x",ORD[c]);else out=out c}return out "\""}
function jsonval(v, out,i,k){if(v==NONE)return "null";if(substr(v,1,1)=="\035")return jsonquote(text(v));if(isobj(v)){out=T[v]=="dict"?"{":"[";for(i=0;i<N[v];i++){if(i)out=out ",";k=K[v,i];out=out (T[v]=="dict"?jsonquote(k) ":":"") jsonval(V[v,k])}return out (T[v]=="dict"?"}":"]")}return sprintf("%.15g",v)}
function g_stable_hash(v, s,i,a,b){s=jsonval(v);a=17;b=29;for(i=1;i<=length(s);i++){a=(a*131+ORD[substr(s,i,1)])%2147483563;b=(b*137+ORD[substr(s,i,1)])%2147483399}return box(sprintf("%08x%08x",a,b))}
function fatal(message){print "site-generator: " message > "/dev/stderr";exit 1}
function init_runtime( i,lo,up,c){NONE="\036";CONVFMT="%.17g";OFMT="%.17g";for(i=1;i<256;i++)ORD[sprintf("%c",i)]=i;lo="абвгдеёжзийклмнопрстуфхцчшщъыьэюя";up="АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ";for(i=1;i<=length(lo);i+=2){UPPER[substr(lo,i,2)]=substr(up,i,2);LOWER[substr(up,i,2)]=substr(lo,i,2)}}
