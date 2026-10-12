#include <windows.h>
#include <stdio.h>
#include <string.h>
static volatile LONG handled;
static LONG CALLBACK handle( EXCEPTION_POINTERS *exception )
{
    if (exception->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_CONTINUE_SEARCH;
    if (exception->ExceptionRecord->NumberParameters < 2 || exception->ExceptionRecord->ExceptionInformation[1] != 0) return EXCEPTION_CONTINUE_SEARCH;
    exception->ContextRecord->Rsp = exception->ContextRecord->R11;
    exception->ContextRecord->Rip += 3; /* 48 8b 00: movq (%rax),%rax */
    handled++;
    return EXCEPTION_CONTINUE_EXECUTION;
}
static __attribute__((naked,noinline)) void control_fault(void)
{
    __asm__ volatile("movq %rsp,%r11\n\txorq %rax,%rax\n\tmovq (%rax),%rax\n\tmovq %r11,%rsp\n\tret");
}
static __attribute__((naked,noinline)) void null_rsp_fault(void)
{
    __asm__ volatile("movq %rsp,%r11\n\txorq %rax,%rax\n\txorq %rsp,%rsp\n\tmovq (%rax),%rax\n\tmovq %r11,%rsp\n\tret");
}
int main(int argc,char **argv)
{
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    void *registration;
    int is_null;
    if (argc != 2 || (strcmp(argv[1],"control") && strcmp(argv[1],"nullrsp"))) return 2;
    is_null = !strcmp(argv[1],"nullrsp");
    if (!(registration = AddVectoredExceptionHandler(1,handle))) return 3;
    if (is_null) null_rsp_fault(); else control_fault();
    RemoveVectoredExceptionHandler(registration);
    printf("mode=%s process_id=%lu thread_id=%lu handled_faults=%ld\n",is_null?"nullrsp":"control",GetCurrentProcessId(),GetCurrentThreadId(),handled);
    return handled == 1 ? 0 : 4;
}
