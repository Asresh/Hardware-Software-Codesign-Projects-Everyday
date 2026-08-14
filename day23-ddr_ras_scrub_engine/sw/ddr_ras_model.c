/* Author: Asresh. Bit-exact shortened Hamming SECDED reference model. */
#include "ddr_ras.h"
static int is_parity(unsigned p){return p&&((p&(p-1u))==0);}
uint64_t ras_encode(uint32_t data){uint64_t c=0;unsigned di=0,p,b;for(p=1;p<=38;++p)if(!is_parity(p)){c|=(uint64_t)((data>>di)&1u)<<(p-1);++di;}for(b=0;b<6;++b){unsigned x=0;for(p=1;p<=38;++p)if((p&(1u<<b))&&((c>>(p-1))&1u))x^=1u;c|=(uint64_t)x<<((1u<<b)-1u);} {unsigned x=0;for(p=0;p<38;++p)x^=(unsigned)((c>>p)&1u);c|=(uint64_t)x<<38;}return c;}
uint64_t ras_check(uint64_t c,unsigned *fixed,unsigned *bad){unsigned syn=0,odd=0,p;*fixed=0;*bad=0;for(p=1;p<=38;++p)if((c>>(p-1))&1u){syn^=p;odd^=1u;}odd^=(unsigned)((c>>38)&1u);if(odd&&syn<=38){c^=UINT64_C(1)<<(syn?syn-1:38);*fixed=1;}else if(syn)*bad=1;return c&((UINT64_C(1)<<39)-1u);}
