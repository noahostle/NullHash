#define P(x) _Pragma(#x)
typedef struct{unsigned h[8],Nl,Nh                                                              ,data[16],num,md_len;}S;extern int I()__asm__ 
("SHA256""_Init"),H()__asm__("SHA256"                                                           "_Updat""e"),F()__asm__("SHA256""_Final"      
          );extern                double                                                                    T()__asm__("omp_ge"   
               "t_wtim"            "e");                                                                        extern void O()
                  __asm__                                                                                        ("omp_se"   
                                                                                                                  "t_num_"   
                                                                                                                  "thread"  
                                          "s"                                                                      );extern 
                                            int                                                                    atoi()   
                          ,printf            (const                                                                char*,...
                          ),open()             ,close                                                              (),fsync 
                          (),rename                                                                                ();extern
                          long read()             ,write                                                           ();extern
                          void(*signal              ())(                                                           );typedef
                          unsigned long               long                                                         U;typedef
                          unsigned                     char D                                                      ;volatile
                          int X;       U N,B=            ~0ULL;                                                    int Z=-1;
                          S C;void      q(int             x){X=1                                                   ;}int s(U
                          n,char*o        ){char            r[16                                                   ];int k= 
                          0,j;n++;          while             (n){r                                                [k++]=33+
                          (n-1)%94           ;n=(n-            1)/94;                                              }for(j=0;
                          j<k;j++)             o[j]=r            [k-j-1                                            ];o[k]=0;
                          return k               ;}int            z(D                                              *d){int n
                          =0;while                (n<64             &&!((                                          d[n>>1]>>
                          (4*(1-(n                  &1))))            &15))n                                       ++;return
                          n;                          }void            h(U i                                       ,D*d,char
                          *a){S c                      =C;int            l=s                                       (i,a);H(&
                          c,a,l);F                       (d,&c)            ;}void                                  p(U i,int
                          n,D*d                           ,char*            a){int                                 j;printf(
                          "%2d ze"                                                                                 "ros | " 
                          "%llu |"                                                                                 " noah " 
                          "ostle%"                                                                                 "s | "   
                          ,n,i,                                  a);for            (j=0                            ;j<32;j++
                          )printf                                 (                 "%02x"                         ,d[j]    
                          );printf                                  ("\n")            ;}void                       w(){U    
                          a[2]={N,                                    B};int            f=open                     ("vanity"
                          "sha.ch"                                     "k~"              ,577                      ,0600);if
                          (f>=0){                                        write(            f,a,16                  );fsync( 
                          f);close                                         (f);              rename                ("vanity"
                          "sha.ch"                                                            "k~"                 ,"vanity"
                          "sha.ch"                                                                                 "k");}}  
                          int main                                              (int              c,               char**v){
                          U a[2],i                                               ,e;int            f,j             ,l;double
                          t;char u                                                 [16];D            d[32]         ;if(c>1)O
                          (atoi(v[                                                   1]));            signal       (2,q     
                          );signal                                                    (15               ,q);I(     &C);H(&C,
                          "noah o"                                                                                 "stle"   
                          ,10                                                            );if((            f=open  ("vanity"
                          "sha.ch"                                                         "k",              0))>=0){if(read
                          (f,a,16                                                            )==16             )N=a[0],B=a[1
                          ];close(                                                            f);}if            (B!=~0ULL)h 
                          (B,d,u),                                                              Z=z(d)            ,p(B,Z,d,u
                          );printf                                                                                 ("start "
                          "%llu\n"                                                                                 ,N);t=T  
                          ();while                                                                   (!X)          {U b=N;e=
                          b+1000000                                                                   ;P(omp       parallel 
                         ){int                                                                          L=-1;      P(omp for
                         schedule(                                                                        static   ))for(i  
                         =b;i<e;i++                                                                        ){if(X  )continue
                         ;char                                                                               a[16];D d[32]  
                        ;S c=C;int l                                                                           =s(i,a);H(&c,
                      a,l);F(d,&c);int                                                                          n=z(d);if(n>
                  L){L=n;P(omp critical){if                                                                       (n>Z){Z=n;
       B=i;p(i,n,d,a);}}}}}if(X)break;N=e;if(T()-t>10                                                               )w(),t= 
       T();}w();printf("saved ""%llu\n",N);return 0;}                                                                       
                                                                                                                            
