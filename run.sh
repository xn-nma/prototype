#!/bin/sh

LUA_CPATH_5_3="${LUA_CPATH_5_3:+"${LUA_CPATH_5_3}";}../lua-hydrogen/?.so" \
	exec lua "$*"
