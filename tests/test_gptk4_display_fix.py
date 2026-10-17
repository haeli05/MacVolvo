"""Fullscreen geometry guard; no game, Wine process or display mode changes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class GPTK4DisplayFix(unittest.TestCase):
    def test_only_oversized_borderless_fullscreen_at_monitor_origin_is_corrected(self):
        source=r'''
#define MACVOLVO_DISPLAY_FIX_GEOMETRY_ONLY
#include "gptk4_display_fix.h"
#include <assert.h>
int main(void) {
    MVDisplayRect monitor={0,0,1920,1200},old={0,0,3024,1964},fit={0,0,1920,1200};
    assert(mvOversizedFullscreen(old,old,monitor,true,false));
    assert(!mvOversizedFullscreen(fit,fit,monitor,true,false));
    assert(!mvOversizedFullscreen(old,old,monitor,false,false));
    assert(!mvOversizedFullscreen(old,old,monitor,true,true));
    MVDisplayRect moved={100,100,3124,2064};
    assert(!mvOversizedFullscreen(old,moved,monitor,true,false));
    MVDisplayRect small={0,0,1280,720};
    assert(!mvOversizedFullscreen(small,small,monitor,true,false));
    MVDisplayRect left={-1920,0,0,1200},onLeft={-1920,0,1104,1964};
    assert(mvOversizedFullscreen(old,onLeft,left,true,false));
    assert(!mvOversizedFullscreen(old,old,(MVDisplayRect){0,0,0,0},true,false));
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='macvolvo-display-geometry-') as temporary:
            folder=Path(temporary)
            path=folder/'geometry.c';path.write_text(source)
            binary=folder/'geometry'
            subprocess.run(['/usr/bin/clang','-std=c11','-Wall','-Wextra','-Werror',
                            '-I',str(ROOT/'scripts'),str(path),'-o',str(binary)],check=True,capture_output=True)
            subprocess.run([str(binary)],check=True,timeout=5)


if __name__=='__main__':
    unittest.main()
