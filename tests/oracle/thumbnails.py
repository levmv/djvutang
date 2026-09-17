#!/usr/bin/env python3
"""External DjVuLibre thumbnail API witness; no header/development package needed.

Usage: tests/oracle/thumbnails.py INPUT PAGE WIDTH HEIGHT OUTPUT.ppm (PAGE is one-based).
The caller selects a stored thumbnail; this helper can also invoke DjVuLibre's
fallback renderer and therefore is not an oracle for thumbnail *absence*.
"""
import ctypes as c
import ctypes.util
from pathlib import Path
import sys
import time


def render(path, page, width, height):
    library = ctypes.util.find_library('djvulibre')
    if not library: raise RuntimeError('DjVuLibre shared library is required')
    lib = c.CDLL(library)
    ptr, integer = c.c_void_p, c.c_int
    for name, restype, args in [
        ('context_create', ptr, [c.c_char_p]), ('context_release', None, [ptr]),
        ('document_create_by_filename_utf8', ptr, [ptr, c.c_char_p, integer]),
        ('document_job', ptr, [ptr]), ('job_status', integer, [ptr]), ('job_release', None, [ptr]),
        ('message_peek', ptr, [ptr]), ('message_pop', None, [ptr]),
        ('thumbnail_status', integer, [ptr, integer, integer]),
        ('format_create', ptr, [integer, integer, ptr]), ('format_release', None, [ptr]),
        ('format_set_row_order', None, [ptr, integer]), ('format_set_y_direction', None, [ptr, integer]),
        ('format_set_ditherbits', None, [ptr, integer]),
        ('thumbnail_render', integer, [ptr, integer, c.POINTER(integer), c.POINTER(integer), ptr, c.c_ulong, ptr]),
    ]:
        fn = getattr(lib, 'ddjvu_' + name)
        fn.restype, fn.argtypes = restype, args
    context = lib.ddjvu_context_create(b'djvutang-thumbnail-test')
    document = lib.ddjvu_document_create_by_filename_utf8(context, str(Path(path).resolve()).encode(), 0)
    if not document: raise RuntimeError('DjVuLibre could not create document')
    job = lib.ddjvu_document_job(document)
    format = lib.ddjvu_format_create(1, 0, None)  # RGB24; display gamma defaults to 2.2.
    try:
        def wait(status):
            deadline = time.monotonic() + 15
            while (value := status()) < 2:
                while lib.ddjvu_message_peek(context): lib.ddjvu_message_pop(context)
                if time.monotonic() > deadline: raise TimeoutError('DjVuLibre thumbnail')
                time.sleep(.001)
            if value != 2: raise RuntimeError(f'DjVuLibre status {value}')
        wait(lambda: lib.ddjvu_job_status(job))
        wait(lambda: lib.ddjvu_thumbnail_status(document, page-1, 1))
        lib.ddjvu_format_set_row_order(format, 1)
        lib.ddjvu_format_set_y_direction(format, 1)
        lib.ddjvu_format_set_ditherbits(format, 24)
        w, h = integer(width), integer(height)
        buffer = c.create_string_buffer(width*height*3)
        if not lib.ddjvu_thumbnail_render(document, page-1, c.byref(w), c.byref(h), format, width*3, buffer):
            raise RuntimeError('DjVuLibre thumbnail unavailable')
        if (w.value, h.value) != (width, height): raise RuntimeError(f'Unexpected thumbnail dimensions: {w.value}x{h.value}')
        return f'P6\n{width} {height}\n255\n'.encode() + buffer.raw
    finally:
        lib.ddjvu_format_release(format)
        lib.ddjvu_job_release(job)
        lib.ddjvu_context_release(context)


if __name__ == '__main__':
    Path(sys.argv[5]).write_bytes(render(sys.argv[1], *map(int, sys.argv[2:5])))
