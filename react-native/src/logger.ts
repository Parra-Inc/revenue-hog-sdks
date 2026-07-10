import type { LogLevel } from './types';

const order: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
  silent: 4,
};

export class Logger {
  constructor(private readonly level: LogLevel = 'warn') {}

  debug(msg: string): void {
    this.emit('debug', msg);
  }
  info(msg: string): void {
    this.emit('info', msg);
  }
  warn(msg: string): void {
    this.emit('warn', msg);
  }
  error(msg: string): void {
    this.emit('error', msg);
  }

  private emit(at: LogLevel, msg: string): void {
    if (this.level === 'silent' || order[at] < order[this.level]) return;
    // eslint-disable-next-line no-console
    console.log(`[revenuehog] ${msg}`);
  }
}
