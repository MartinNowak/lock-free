lock-free [![Build Status](https://travis-ci.org/MartinNowak/lock-free.png)](https://travis-ci.org/MartinNowak/lock-free)
=========

A library for lock-free data structures.

Currently the library contains a [Doubly-Linked List](https://github.com/MartinNowak/lock-free/blob/master/src/lock_free/dlist.d "AtomicDList") and a [single-reader single-writer queue](https://github.com/MartinNowak/lock-free/blob/master/src/lock_free/rwqueue.d "RWQueue").
DList is based on the paper [Lock-free deques and doubly linked lists](http://dx.doi.org/10.1016/j.jpdc.2008.03.001).
A good description of SRSW queues can be found [here](http://www.codeproject.com/Articles/43510/Lock-Free-Single-Producer-Single-Consumer-Circular "Lock-Free Single-Producer - Single Consumer Circular Queue - CodeProject")

They doubly-linked list still needs a thorough review and some polishing. That said all unittests pass on X86_64, no warranty though!
