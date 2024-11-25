#!/bin/bash
echo $FOO   # ShellCheck issue: Double quote to prevent globbing
cd $(pwd)   # ShellCheck issue: Double quote to prevent globbing