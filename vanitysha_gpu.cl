#define ROR(x,n) rotate((x),(uint)(32-(n)))
#define CH(x,y,z) bitselect((z),(y),(x))
#define MAJ(x,y,z) bitselect((x),(y),(x)^(z))
#define B0(x) (ROR((x),2)^ROR((x),13)^ROR((x),22))
#define B1(x) (ROR((x),6)^ROR((x),11)^ROR((x),25))
#define S0(x) (ROR((x),7)^ROR((x),18)^((x)>>3))
#define S1(x) (ROR((x),17)^ROR((x),19)^((x)>>10))
#define X(i) (w[(i)]+=S0(w[((i)+1)&15])+w[((i)+9)&15]+S1(w[((i)+14)&15]))
#define R(x,k) do{uint T1=h+B1(e)+CH(e,f,g)+(uint)(k)+(uint)(x),T2=B0(a)+MAJ(a,b,c);h=g;g=f;f=e;e=d+T1;d=c;c=b;b=a;a=T1+T2;}while(0)

inline uint hz(uint a,uint b,uint c,uint d,uint e,uint f,uint g,uint h){
    uint q,z=0;
    q=clz(a+0x6a09e667U)>>2; z+=q; if(q<8)return z;
    q=clz(b+0xbb67ae85U)>>2; z+=q; if(q<8)return z;
    q=clz(c+0x3c6ef372U)>>2; z+=q; if(q<8)return z;
    q=clz(d+0xa54ff53aU)>>2; z+=q; if(q<8)return z;
    q=clz(e+0x510e527fU)>>2; z+=q; if(q<8)return z;
    q=clz(f+0x9b05688cU)>>2; z+=q; if(q<8)return z;
    q=clz(g+0x1f83d9abU)>>2; z+=q; if(q<8)return z;
    q=clz(h+0x5be0cd19U)>>2; return z+q;
}

__attribute__((reqd_work_group_size(256,1,1)))
__kernel void search(ulong abs0, ulong off0, uint L, ulong count, uint iters, __global ulong2 *out){
    const uint lid=get_local_id(0), gid=get_global_id(0), grp=get_group_id(0);
    const ulong rel=(ulong)gid*(ulong)iters;
    uint bz=0; ulong bi=~(ulong)0;
    __local uint Z[256];
    __local ulong I[256];

    if(rel<count){
        uint m[6]={0x6e6f6168U,0x206f7374U,0x6c650000U,0,0,0}; /* "noah ostle" */
        ulong x=off0+rel;
        for(int p=(int)L-1;p>=0;--p){
            const uint pos=10U+(uint)p, sh=24U-8U*(pos&3U);
            const uint ch=33U+(uint)(x%94UL);
            x/=94UL;
            m[pos>>2]|=ch<<sh;
        }
        {
            const uint pos=10U+L, sh=24U-8U*(pos&3U);
            m[pos>>2]|=0x80U<<sh;
        }
        const uint bitlen=(10U+L)*8U;
        const ulong left=count-rel;
        const uint n=(uint)min((ulong)iters,left);

        for(uint j=0;j<n;++j){
            uint w[16];
            w[0]=m[0];w[1]=m[1];w[2]=m[2];w[3]=m[3];w[4]=m[4];w[5]=m[5];
            w[6]=0;w[7]=0;w[8]=0;w[9]=0;w[10]=0;w[11]=0;w[12]=0;w[13]=0;w[14]=0;w[15]=bitlen;
            uint a=0x6a09e667U,b=0xbb67ae85U,c=0x3c6ef372U,d=0xa54ff53aU,e=0x510e527fU,f=0x9b05688cU,g=0x1f83d9abU,h=0x5be0cd19U;

            R(w[0], 0x428a2f98U);R(w[1], 0x71374491U);R(w[2], 0xb5c0fbcfU);R(w[3], 0xe9b5dba5U);
            R(w[4], 0x3956c25bU);R(w[5], 0x59f111f1U);R(w[6], 0x923f82a4U);R(w[7], 0xab1c5ed5U);
            R(w[8], 0xd807aa98U);R(w[9], 0x12835b01U);R(w[10],0x243185beU);R(w[11],0x550c7dc3U);
            R(w[12],0x72be5d74U);R(w[13],0x80deb1feU);R(w[14],0x9bdc06a7U);R(w[15],0xc19bf174U);
            R(X(0), 0xe49b69c1U);R(X(1), 0xefbe4786U);R(X(2), 0x0fc19dc6U);R(X(3), 0x240ca1ccU);
            R(X(4), 0x2de92c6fU);R(X(5), 0x4a7484aaU);R(X(6), 0x5cb0a9dcU);R(X(7), 0x76f988daU);
            R(X(8), 0x983e5152U);R(X(9), 0xa831c66dU);R(X(10),0xb00327c8U);R(X(11),0xbf597fc7U);
            R(X(12),0xc6e00bf3U);R(X(13),0xd5a79147U);R(X(14),0x06ca6351U);R(X(15),0x14292967U);
            R(X(0), 0x27b70a85U);R(X(1), 0x2e1b2138U);R(X(2), 0x4d2c6dfcU);R(X(3), 0x53380d13U);
            R(X(4), 0x650a7354U);R(X(5), 0x766a0abbU);R(X(6), 0x81c2c92eU);R(X(7), 0x92722c85U);
            R(X(8), 0xa2bfe8a1U);R(X(9), 0xa81a664bU);R(X(10),0xc24b8b70U);R(X(11),0xc76c51a3U);
            R(X(12),0xd192e819U);R(X(13),0xd6990624U);R(X(14),0xf40e3585U);R(X(15),0x106aa070U);
            R(X(0), 0x19a4c116U);R(X(1), 0x1e376c08U);R(X(2), 0x2748774cU);R(X(3), 0x34b0bcb5U);
            R(X(4), 0x391c0cb3U);R(X(5), 0x4ed8aa4aU);R(X(6), 0x5b9cca4fU);R(X(7), 0x682e6ff3U);
            R(X(8), 0x748f82eeU);R(X(9), 0x78a5636fU);R(X(10),0x84c87814U);R(X(11),0x8cc70208U);
            R(X(12),0x90befffaU);R(X(13),0xa4506cebU);R(X(14),0xbef9a3f7U);R(X(15),0xc67178f2U);

            const uint z=hz(a,b,c,d,e,f,g,h);
            const ulong idx=abs0+rel+(ulong)j;
            if(z>bz || (z==bz && idx<bi)){bz=z;bi=idx;}

            if(j+1U<n){
                for(int p=(int)L-1;p>=0;--p){
                    const uint pos=10U+(uint)p, wi=pos>>2, sh=24U-8U*(pos&3U);
                    const uint mask=0xffU<<sh, v=(m[wi]>>sh)&0xffU;
                    if(v<126U){m[wi]=(m[wi]&~mask)|((v+1U)<<sh);break;}
                    m[wi]=(m[wi]&~mask)|(33U<<sh);
                }
            }
        }
    }

    Z[lid]=bz;I[lid]=bi;
    barrier(CLK_LOCAL_MEM_FENCE);
    for(uint s=128U;s;s>>=1){
        if(lid<s){
            const uint z=Z[lid+s]; const ulong i=I[lid+s];
            if(z>Z[lid] || (z==Z[lid] && i<I[lid])){Z[lid]=z;I[lid]=i;}
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    if(!lid)out[grp]=(ulong2)((ulong)Z[0],I[0]);
}
