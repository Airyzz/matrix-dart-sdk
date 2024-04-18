#!/bin/bash

thread_count=$(getconf _NPROCESSORS_ONLN)

if [ -n "$NO_OLM" ]; then 
    tagFlag="-x"
else
    tagFlag="-t"
fi


dart test --concurrency=$thread_count --coverage=$1 $tagFlag 'olm'

# lets you do more stuff like reporton
dart pub global activate coverage
dart pub global run coverage:format_coverage --lcov -i $1 -o $1/lcov.info --report-on=lib/
dart pub global activate remove_from_coverage
dart pub global run remove_from_coverage:remove_from_coverage -f $1/lcov.info -r '\.g\.dart$'
