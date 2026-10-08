#include <stdio.h>
__attribute__((constructor)) static void injected(void) { puts("injected-code"); }
