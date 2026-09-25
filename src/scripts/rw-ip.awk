# Strict IPv4/IPv6/CIDR parsing for installer validation (POSIX awk).
# Inputs arrive through environment variables, never awk source or -v escapes.
function fail(){exit 1}
function trim(s){sub(/^[ \t\r\n]+/,"",s);sub(/[ \t\r\n]+$/,"",s);return s}
function ipv4(s,out, a,n,i){n=split(s,a,".");if(n!=4)return 0;for(i=1;i<=4;i++){if(a[i]!~/^[0-9]+$/ || length(a[i])>3 || (length(a[i])>1 && substr(a[i],1,1)=="0") || a[i]+0>255)return 0;out[i]=a[i]+0}return 1}
function hexnum(s, i,n,c){n=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",substr(s,i,1))-1;if(c<0)return -1;n=n*16+c}return n}
function parse(s, a,n,addr,prefix,i,pos,left,right,nl,nr,l,r,v4,last,group,bits,mask,p){
    for(i in P)delete P[i];
    n=split(s,a,"/");if(n>2 || n<1)return 0;addr=tolower(a[1]);HAS_PREFIX=n==2;
    PV=index(addr,":")?6:4;WIDTH=PV==4?8:16;COUNT=PV==4?4:8;PREFIX=PV==4?32:128;
    if(PV==4){if(!ipv4(addr,P))return 0}
    else {
        if(addr!~/^[0-9a-f:.]+$/)return 0;
        if(index(addr,".")){
            last=0;for(i=1;i<=length(addr);i++)if(substr(addr,i,1)==":")last=i;
            if(!last || !ipv4(substr(addr,last+1),v4))return 0;
            addr=substr(addr,1,last) sprintf("%x:%x",v4[1]*256+v4[2],v4[3]*256+v4[4]);
        }
        pos=index(addr,"::");
        if(pos){
            left=substr(addr,1,pos-1);right=substr(addr,pos+2);
            if(index(right,"::"))return 0;
            nl=left==""?0:split(left,l,":");nr=right==""?0:split(right,r,":");
            if(nl+nr>=8)return 0;
            for(i=1;i<=nl;i++){if(length(l[i])<1 || length(l[i])>4)return 0;P[i]=hexnum(l[i])}
            for(i=nl+1;i<=8-nr;i++)P[i]=0;
            for(i=1;i<=nr;i++){if(length(r[i])<1 || length(r[i])>4)return 0;P[8-nr+i]=hexnum(r[i])}
        }else{
            if(split(addr,l,":")!=8)return 0;
            for(i=1;i<=8;i++){if(length(l[i])<1 || length(l[i])>4)return 0;P[i]=hexnum(l[i])}
        }
        for(i=1;i<=8;i++)if(P[i]<0)return 0;
    }
    if(HAS_PREFIX){
        prefix=a[2];
        if(prefix~/^[0-9]+$/){if(length(prefix)>3 || prefix+0>PREFIX)return 0;PREFIX=prefix+0}
        else if(PV==4 && ipv4(prefix,v4)){
            # IPv4 dotted netmasks/hostmasks, accepted by the old parser too.
            mask=v4[1]*16777216+v4[2]*65536+v4[3]*256+v4[4];
            if(v4[1]==0 && mask!=0)mask=4294967295-mask;
            p=0;while(mask>=2147483648){p++;mask=(mask-2147483648)*2}
            if(mask!=0)return 0;PREFIX=p;
        }else return 0;
        bits=PREFIX;
        for(i=1;i<=COUNT;i++){group=bits>=WIDTH?WIDTH:bits<=0?0:bits;P[i]=int(P[i]/2^(WIDTH-group))*2^(WIDTH-group);bits-=WIDTH}
    }
    return 1;
}
function normalized( s,i,best,start,run,len){
    s="";
    if(PV==4){for(i=1;i<=4;i++)s=s (i>1?".":"") P[i]}
    else {
        best=0;len=0;
        for(i=1;i<=8;){if(P[i]!=0){i++;continue}start=i;while(i<=8 && P[i]==0)i++;run=i-start;if(run>len && run>=2){best=start;len=run}}
        for(i=1;i<=8;){if(i==best){s=s "::";i+=len;continue}if(s!="" && substr(s,length(s),1)!=":")s=s ":";s=s sprintf("%x",P[i]);i++}
    }
    return s (HAS_PREFIX?"/" PREFIX:"");
}
BEGIN {
    mode=ENVIRON["RW_IP_MODE"];raw=ENVIRON["RW_IP_INPUT"];
    if(mode=="version"){if(!parse(raw))fail();print PV;exit}
    if(mode=="in-list"){
        if(index(raw,"/") || !parse(raw))fail();version=PV;for(i=1;i<=COUNT;i++)A[i]=P[i];
        raw=ENVIRON["RW_IP_LIST"];
    }
    parts=split(raw,items,",");result="";found=0;
    for(part=1;part<=parts;part++){
        value=trim(items[part]);if(value=="")continue;
        if(!parse(value))fail();
        if(mode=="normalize"){
            value=normalized();if(!(value in seen)){result=result (result!=""?",":"") value;seen[value]=1}
        }else if(mode=="world"){if(HAS_PREFIX && PREFIX==0)found=1}
        else if(mode=="in-list" && PV==version){
            matchip=1;bits=PREFIX;
            for(i=1;i<=COUNT;i++){usebits=bits>=WIDTH?WIDTH:bits<=0?0:bits;factor=2^(WIDTH-usebits);if(int(A[i]/factor)!=int(P[i]/factor))matchip=0;bits-=WIDTH}
            if(matchip)found=1;
        }
    }
    if(mode=="normalize"){if(result=="")fail();print result;exit}
    exit !found;
}
