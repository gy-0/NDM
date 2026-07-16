CREATE TABLE "downloads" (
	"id"	INTEGER,
	"url"	TEXT,
	"method"	TEXT,
	"filename"	TEXT,
	"ltype"	TEXT,
	"filesize"	NUMERIC,
	"category"	TEXT,
	"status"	TEXT,
	"bandwidthlimit"	NUMERIC,
	"connections"	NUMERIC,
	"lasttry"	NUMERIC,
	"firsttry"	NUMERIC,
	"useragent"	TEXT,
	"resumable"	NUMERIC,
	"pageurl"	TEXT,
	"pagetitle"	TEXT,
	"hittitle"	TEXT,
	"mimetype"	TEXT,
	"errortext"	TEXT,
	"urla"	TEXT,
	"postdata"	TEXT,
	"folderpath"	TEXT,
	PRIMARY KEY("id")
);
CREATE TABLE auths (id INTEGER PRIMARY KEY AUTOINCREMENT ,target TEXT,protocol TEXT,user TEXT, pass TEXT );
CREATE TABLE headers (id NUMERIC, header TEXT);
