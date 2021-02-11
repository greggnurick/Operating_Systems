/* Copyright (C) 2017 Daniel Page <csdsp@bristol.ac.uk>
 *
 * Use of this source code is restricted per the CC BY-NC-ND license, a copy of 
 * which can be found via http://creativecommons.org (and should be included as 
 * LICENSE.txt within the associated archive or repository).
 */

#include "hilevel.h"
#define numberOfProcesses 100
#define processWidth 0x00001000

pcb_t pcb[numberOfProcesses];
pcb_t *current = NULL;

pipe_t pipes[numberOfProcesses];

pid_t findPID()
{
  pid_t pid;
  for (int i = 0; i <= numberOfProcesses; i++)
  {
    if (pcb[i].status == STATUS_TERMINATED)
    {
      return i;
    }
  }
}

int findPipe()
{
  for (int i = 0; i < numberOfProcesses; i++)
  {
    if (pipes[i].active == false)
    {
      return i;
    }
  }
  return -1;
}

int findPipeWriter(int fd)
{
  for (int i = 0; i < numberOfProcesses; i++)
  {
    if (pipes[i].fileDes[0] == current->pid && pipes[i].fileDes[1] == fd)
    {
      return i;
    }
  }
  return -1;
}

int findPipeReader(int fd)
{
  for (int i = 0; i < numberOfProcesses; i++)
  {
    if (pipes[i].fileDes[0] == fd && pipes[i].fileDes[1] == current->pid)
    {
      return i;
    }
  }
  return -1;
}

void dispatch(ctx_t *ctx, pcb_t *prev, pcb_t *next)
{
  char prev_pid = '?', next_pid = '?';

  if (NULL != prev)
  {
    memcpy(&prev->ctx, ctx, sizeof(ctx_t)); // preserve execution context of P_{prev}
    prev_pid = '0' + prev->pid;
  }
  if (NULL != next)
  {
    memcpy(ctx, &next->ctx, sizeof(ctx_t)); // restore  execution context of P_{next}
    next_pid = '0' + next->pid;
  }

  PL011_putc(UART0, '[', true);
  PL011_putc(UART0, prev_pid, true);
  PL011_putc(UART0, '-', true);
  PL011_putc(UART0, '>', true);
  PL011_putc(UART0, next_pid, true);
  PL011_putc(UART0, ']', true);

  current = next; // update   executing index   to P_{next}

  return;
}

void schedule(ctx_t *ctx)
{
  int cur;
  for (int i = 0; i < numberOfProcesses; i++)
  {
    if (pcb[i].status != STATUS_EXECUTING && pcb[i].status != STATUS_TERMINATED)
    {
      pcb[i].age++;
    }
    else if (pcb[i].status == STATUS_EXECUTING)
    {
      cur = i;
    }
  }

  int top = 0;
  for (int i = 1; i < numberOfProcesses; i++)
  {
    if ((pcb[i].priority + pcb[i].age >= pcb[top].priority + pcb[top].age) && pcb[i].status != STATUS_TERMINATED)
    {
      top = i;
    }
  }

  if (&pcb[top] == current)
  {
    return;
  }

  dispatch(ctx, &pcb[cur], &pcb[top]);

  pcb[top].age = 0;
  pcb[cur].status = STATUS_READY;     // update   execution status  of P_3
  pcb[top].status = STATUS_EXECUTING; // update   execution status  of P_4

  return;
}

extern void main_console();
extern uint32_t tos_console;
extern uint32_t tos_processes;

void hilevel_handler_rst(ctx_t *ctx)
{
  /* Configure the mechanism for interrupt handling by
   *
   * - configuring timer st. it raises a (periodic) interrupt for each 
   *   timer tick,
   * - configuring GIC st. the selected interrupts are forwarded to the 
   *   processor via the IRQ interrupt signal, then
   * - enabling IRQ interrupts.
   */

  TIMER0->Timer1Load = 0x00100000;  // select period = 2^20 ticks ~= 1 sec
  TIMER0->Timer1Ctrl = 0x00000002;  // select 32-bit   timer
  TIMER0->Timer1Ctrl |= 0x00000040; // select periodic timer
  TIMER0->Timer1Ctrl |= 0x00000020; // enable          timer interrupt
  TIMER0->Timer1Ctrl |= 0x00000080; // enable          timer

  GICC0->PMR = 0x000000F0;         // unmask all            interrupts
  GICD0->ISENABLER1 |= 0x00000010; // enable timer          interrupt
  GICC0->CTLR = 0x00000001;        // enable GIC interface
  GICD0->CTLR = 0x00000001;        // enable GIC distributor

  memset(&pcb[0], 0, sizeof(pcb_t)); // initialise 0-th PCB
  pcb[0].pid = 0;
  pcb[0].status = STATUS_EXECUTING;
  pcb[0].priority = 1;
  pcb[0].age = 0;
  pcb[0].ctx.cpsr = 0x50;
  pcb[0].ctx.pc = (uint32_t)(&main_console);
  pcb[0].ctx.sp = (uint32_t)(&tos_console);
  pcb[0].topOfStack = (uint32_t)(&tos_console);

  for (int i = 1; i < numberOfProcesses; i++)
  {
    memset(&pcb[i], 0, sizeof(pcb_t));
    pcb[i].pid = -1;
    pcb[i].status = STATUS_TERMINATED;
    pcb[i].ctx.cpsr = 0;
    pcb[i].ctx.pc = 0;
    pcb[i].ctx.sp = 0;
    pcb[i].topOfStack = 0;
    pcb[i].age = 0;
    pcb[i].priority = 0;
  }

  for (int i = 0; i < numberOfProcesses; i++)
  {
    memset(&pipes[i], 0, sizeof(pipe_t));
    pipes[i].pipeID = -1;
    pipes[i].fileDes[0] = -1;
    pipes[i].fileDes[1] = -1;
    pipes[i].active = false;
    pipes[i].notEmpty = false;
    pipes[i].buffer = 0;
  }

  dispatch(ctx, NULL, &pcb[0]);

  int_enable_irq();

  return;
}

void hilevel_handler_irq(ctx_t *ctx)
{
  // Step 2: read  the interrupt identifier so we know the source.

  uint32_t id = GICC0->IAR;

  // Step 4: handle the interrupt, then clear (or reset) the source.

  if (id == GIC_SOURCE_TIMER0)
  {
    PL011_putc(UART0, 'T', true);
    schedule(ctx);
    TIMER0->Timer1IntClr = 0x01;
  }

  // Step 5: write the interrupt identifier to signal we're done.

  GICC0->EOIR = id;

  return;
}

void hilevel_handler_svc(ctx_t *ctx, uint32_t id)
{
  /* Based on the identifier (i.e., the immediate operand) extracted from the
   * svc instruction, 
   *
   * - read  the arguments from preserved usr mode registers,
   * - perform whatever is appropriate for this system call, then
   * - write any return value back to preserved usr mode registers.
   */

  switch (id)
  {
  case 0x00:
  { // 0x00 => yield()
    break;
  }

  case 0x01:
  { // 0x01 => write( fd, x, n )
    int fd = (int)(ctx->gpr[0]);
    char *x = (char *)(ctx->gpr[1]);
    int n = (int)(ctx->gpr[2]);

    for (int i = 0; i < n; i++)
    {
      PL011_putc(UART0, *x++, true);
    }

    ctx->gpr[0] = n;

    break;
  }

  case 0x03:
  { // 0x04 => fork()

    pid_t childPID = findPID();
    pcb_t *parent = current;
    pcb_t *child = &pcb[childPID];

    uint32_t depthOfParent = parent->topOfStack - ctx->sp;

    child->pid = childPID;
    child->status = STATUS_CREATED;
    child->topOfStack = (uint32_t)&tos_processes - (child->pid * processWidth);
    child->age = 0;
    child->priority = 1;
    child->parent = parent;

    memcpy((void *)(child->topOfStack - processWidth), (void *)(parent->topOfStack - processWidth), processWidth);
    memcpy(&child->ctx, ctx, sizeof(ctx_t));

    child->ctx.sp = child->topOfStack - depthOfParent;
    ctx->gpr[0] = child->pid;
    child->ctx.gpr[0] = 0;

    char addedPID = '0' + child->pid;
    PL011_putc(UART0, '[', true);
    PL011_putc(UART0, '+', true);
    PL011_putc(UART0, addedPID, true);
    PL011_putc(UART0, ']', true);
    //dispatch(ctx, parent, child);

    break;
  }

  case 0x04:
  { // 0x04 => exit(x)

    int x = (int)(ctx->gpr[0]);
    int executing;

    for (int i = 0; i < numberOfProcesses; i++)
    {
      if (pcb[i].status == STATUS_EXECUTING)
      {
        executing = i;
      }
    }

    char exitedPID = '0' + pcb[executing].pid;
    PL011_putc(UART0, '[', true);
    PL011_putc(UART0, '-', true);
    PL011_putc(UART0, exitedPID, true);
    PL011_putc(UART0, ']', true);

    // dispatch(ctx, &pcb[executing], pcb[executing].parent);
    // pcb[executing].parent->status = STATUS_EXECUTING;

    memset(&pcb[executing], 0, sizeof(pcb_t));
    pcb[executing].pid = -1;
    pcb[executing].status = STATUS_TERMINATED;
    pcb[executing].ctx.cpsr = 0;
    pcb[executing].ctx.pc = 0;
    pcb[executing].ctx.sp = 0;
    pcb[executing].topOfStack = 0;
    pcb[executing].age = 0;
    pcb[executing].priority = 0;

    schedule(ctx);

    //TODO EXIT_SUCCESS vs EXIT_FAILIURE

    break;
  }

  case 0x05:
  { // 0x05 => exec(x)

    ctx->sp = current->topOfStack;
    ctx->pc = (uint32_t)ctx->gpr[0];

    PL011_putc(UART0, '[', true);
    PL011_putc(UART0, 's', true);
    PL011_putc(UART0, ']', true);

    break;
  }

  case 0x06:
  { // 0x06 => kill(pid, s)

    pid_t pid = (pid_t)(ctx->gpr[0]);
    int s = ctx->gpr[1];

    char terminatedPID = '0' + pcb[pid].pid;
    PL011_putc(UART0, '[', true);
    PL011_putc(UART0, '/', true);
    PL011_putc(UART0, terminatedPID, true);
    PL011_putc(UART0, ']', true);

    memset(&pcb[pid], 0, sizeof(pcb_t));
    pcb[pid].pid = -1;
    pcb[pid].status = STATUS_TERMINATED;
    pcb[pid].ctx.cpsr = 0;
    pcb[pid].ctx.pc = 0;
    pcb[pid].ctx.sp = 0;
    pcb[pid].topOfStack = 0;
    pcb[pid].age = 0;
    pcb[pid].priority = 0;

    //TODO SIG_TERM vs SIG_QUIT

    break;
  }

  case 0x08:
  { // 0x08 => pipe(pfds[2])

    int *pfds = (int *)(ctx->gpr[0]);

    int emptyPipe = findPipe();
    if (emptyPipe == -1)
    {
      ctx->gpr[0] = -1;
      break;
    }
    else
    {
      int nextPID = findPID();
      memset(&pipes[emptyPipe], 0, sizeof(pipe_t));
      pipes[emptyPipe].pipeID = emptyPipe;
      pipes[emptyPipe].fileDes[0] = current->pid; //writer
      pipes[emptyPipe].fileDes[1] = nextPID;      //reader
      pipes[emptyPipe].notEmpty = false;
      pipes[emptyPipe].active = true;

      pfds[0] = current->pid;
      pfds[1] = nextPID;

      ctx->gpr[0] = 0;

      break;
    }
  }

  case 0x09:
  { //writePipe(fd, x)
    int fd = (int)(ctx->gpr[0]);
    int x = (int)(ctx->gpr[1]);

    int pipeID = findPipeWriter(fd);
    if (pipeID == -1)
    {
      ctx->gpr[0] = -1;
      break;
    }
    else
    {
      if (!pipes[pipeID].notEmpty)
      {
        pipes[pipeID].buffer = (int)(x);
        pipes[pipeID].notEmpty = true;
        ctx->gpr[0] = 0;
      }
      else
      {
        ctx->gpr[0] = -1;
      }
      break;
    }
  }

  case 0x0A:
  { //readPipe(fd)
    int fd = (int)(ctx->gpr[0]);
    int pipeID = findPipeReader(fd);
    if (pipeID == -1)
    {
      ctx->gpr[0] = 0;
      break;
    }
    else
    {
      if (pipes[pipeID].notEmpty)
      {
        int x = pipes[pipeID].buffer;
        pipes[pipeID].buffer = 0;
        pipes[pipeID].notEmpty = false;

        ctx->gpr[0] = x;
      }
      else
      {
        ctx->gpr[0] = 0;
      }
      break;
    }
  }

  case 0x0B:
  { //close(fd)
    int fd = (int)(ctx->gpr[0]);
    int pipeID = findPipeReader(fd);
    if (pipeID == -1)
    {
      ctx->gpr[0] = -1;
      break;
    }
    else
    {
      memset(&pipes[pipeID], 0, sizeof(pipe_t));
      pipes[pipeID].fileDes[0] = -1;
      pipes[pipeID].fileDes[1] = -1;
      pipes[pipeID].notEmpty = false;
      pipes[pipeID].active = false;
      pipes[pipeID].pipeID = -1;
      pipes[pipeID].buffer = 0;

      ctx->gpr[0] = 0;

      break;
    }
  }

  default:
  { // 0x?? => unknown/unsupported

    break;
  }
  }

  return;
}
