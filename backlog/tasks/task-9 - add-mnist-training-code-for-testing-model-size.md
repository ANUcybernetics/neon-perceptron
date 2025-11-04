---
id: task-9
title: add mnist training code for testing model size
status: To Do
assignee: []
created_date: "2025-11-04 10:06"
labels: []
dependencies: []
---

There's another project on this machine
(/Users/ben/Documents/edex/human-scale-ai/perceptron_apparatus) which has code
for:

- downloading the MNIST digits training set
- resizing it (to n pixel \* n pixel square images) and then training a network
  with
  - no bias
  - n^2 inputs, one hidden layer of size m
  - 10 outputs (one for each digit)
- after training, printing the model accuracy

I'd like to have similar functionality in this project. The purpose would be to
explore tradeoffs between model size (m and n in particular) and accuracy on the
MNIST dataset.

Start with n = 5 and m = 9 (so 25 inputs, 9 hidden, 10 output) and print the
results. I think it makes the most sense for this to be a test (or perhaps a mix
task...)

You don't have to copy-paste the code from the perceptron apparatus repo
exactly - slim it down to just what we need here.
