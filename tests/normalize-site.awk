# Normalize insignificant decimal spelling across awk implementations.
# Do not alter layout, text, tags, attribute order or integer values.
{
    remaining=$0
    result=""
    while (match(remaining, /[-+]?[0-9]+\.[0-9]+([eE][-+]?[0-9]+)?/)) {
        before=substr(remaining,1,RSTART-1)
        token=substr(remaining,RSTART,RLENGTH)
        previous=substr(before,length(before),1)
        if (previous !~ /[A-Za-z0-9_#]/) {
            number=token+0
            token=number==0 ? "0" : sprintf("%.8g",number)
        }
        result=result before token
        remaining=substr(remaining,RSTART+RLENGTH)
    }
    print result remaining
}
