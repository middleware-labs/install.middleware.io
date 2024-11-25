#!/bin/bash
echo $FOOO   # ShellCheck issue: Double quote to prevent globbing
cd $(pwd)   # ShellCheck issue: Double quote to prevent globbing