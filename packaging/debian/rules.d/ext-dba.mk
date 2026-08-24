ext_PACKAGES    += dba
dba_DESCRIPTION := DBA
dba_EXTENSIONS  := dba
dba_config = \
	--enable-dba=shared \
	--without-db4 \
	--without-gdbm \
	--with-qdbm=/usr \
	--with-lmdb=/usr \
	--enable-inifile \
	--enable-flatfile
export dba_EXTENSIONS
export dba_DESCRIPTION
