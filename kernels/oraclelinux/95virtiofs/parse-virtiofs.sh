#!/usr/bin/sh

if [ "${root%%:*}" = "virtiofs" ] ; then
   modprobe virtiofs

   rootok=1
fi
