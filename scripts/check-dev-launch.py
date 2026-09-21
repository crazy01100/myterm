#!/usr/bin/env python3
"""Read-only production-process gate for the maintainer's Dev workflow."""
import re
import subprocess
import sys

PRODUCTION = '/Applications/MyTerm.app/Contents/MacOS/MySSHClient'
REMINDER = '退出所有工作並關閉正式版本'


def production_pids(listing):
    """ps comm reports executable paths, not shell arguments containing a path."""
    lines = [line for line in listing.splitlines() if line.strip()]
    if not lines:
        raise ValueError('empty process listing')
    found = []
    for line in lines:
        match = re.fullmatch(r'\s*(\d+)\s+(\S.*)', line)
        if not match:
            raise ValueError('invalid process listing')
        if match.group(2).strip() == PRODUCTION:
            found.append(int(match.group(1)))
    return found


def main():
    try:
        result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,comm='],
                                capture_output=True, text=True, check=True, timeout=10)
        pids = production_pids(result.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        print('無法可靠確認正式版本是否正在執行；已停止 Dev 流程，請先完成程序核對。', file=sys.stderr)
        return 70
    if pids:
        print(f'正式版本仍在執行，已停止 Dev 流程。請先「{REMINDER}」，由你手動關閉後再繼續。', file=sys.stderr)
        print('Production PID: ' + ', '.join(map(str, pids)), file=sys.stderr)
        return 70
    print('Dev launch gate passed: production App is not running.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
