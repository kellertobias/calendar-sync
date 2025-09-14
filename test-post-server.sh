#!/bin/bash

node -e "require('http').createServer((req,res)=>{let d='';req.on('data',c=>d+=c);req.on('end',()=>{console.log(req.method, req.url, d)});res.end()}).listen(3000)"
