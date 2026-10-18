package main

import (
    "syscall"
    "testing"
)

func TestDegradableMetadataErrnos(t *testing.T) {
    yes := []error{syscall.ENOTSUP, syscall.EOPNOTSUPP, syscall.EACCES, syscall.EPERM, syscall.EINVAL}
    for _, err := range yes {
        if !degradable(err) {
            t.Fatalf("expected degradable errno %v", err)
        }
    }
    no := []error{syscall.EIO, syscall.ESTALE, syscall.ENOSPC, syscall.EROFS, syscall.ENOENT}
    for _, err := range no {
        if degradable(err) {
            t.Fatalf("storage/path errno must remain fatal: %v", err)
        }
    }
}
