;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.
;; See the LICENSE file in the project root for more information.

#include "AsmMacros.h"

        TEXTAREA

;; Allocate non-array, non-finalizable object. If the allocation doesn't fit into the current thread's
;; allocation context then automatically fallback to the slow allocation path.
;;  r0 == EEType
        LEAF_ENTRY RhpNewFast

        ;; r1 = GetThread(), TRASHES r2
        INLINE_GETTHREAD r1, r2

        ;; Fetch object size into r2.
        ldr         r2, [r0, #OFFSETOF__EEType__m_uBaseSize]

        ;;
        ;; r0: EEType pointer
        ;; r1: Thread pointer
        ;; r2: base size
        ;;

        ;; Load potential new object address into r3. Cache this result in r12 as well for the common case
        ;; where the allocation succeeds (r3 will be overwritten in the following bounds check).
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]
        mov         r12, r3

        ;; Determine whether the end of the object would lie outside of the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        add         r2, r3
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r3
        bhi         AllocFailed

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the new object's EEType pointer.
        str         r0, [r12, #OFFSETOF__Object__m_pEEType]

        ;; Return the object allocated in r0.
        mov         r0, r12

        bx          lr

AllocFailed
        ;; Fast allocation failed. Call slow helper with flags set to zero (this isn't a finalizable object).
        mov         r1, #0
        b           RhpNewObject

        LEAF_END RhpNewFast

;; Allocate non-array object with finalizer.
;;  r0 == EEType
        LEAF_ENTRY RhpNewFinalizable
        mov         r1, #GC_ALLOC_FINALIZE
        b           RhpNewObject
        LEAF_END RhpNewFinalizable

;; Allocate non-array object.
;;  r0 == EEType
;;  r1 == alloc flags
        NESTED_ENTRY RhpNewObject

        COOP_PINVOKE_FRAME_PROLOG           ; r4 <- Thread

        ; r0: EEType
        ; r1: alloc flags
        ; r4: Thread *

        ;; Preserve the EEType in r5.
        mov         r5, r0

        mov         r3, r5                                      ; pEEType
        mov         r2, r1                                      ; uFlags
        ldr         r1, [r5, #OFFSETOF__EEType__m_uBaseSize]    ; cbSize
        mov         r0, r4                                      ; pThread

        ;; Call the rest of the allocation helper.
        ;; void* RedhawkGCInterface::Alloc(Thread *pThread, UIntNative cbSize, UInt32 uFlags, EEType *pEEType)
        blx         $REDHAWKGCINTERFACE__ALLOC

        ;; Set the new object's EEType pointer on success.
        cbz         r0, NewOutOfMemory
        str         r5, [r0, #OFFSETOF__Object__m_pEEType]

        ;; If the object is bigger than RH_LARGE_OBJECT_SIZE, we must publish it to the BGC
        ldr         r1, [r5, #OFFSETOF__EEType__m_uBaseSize]
        movw        r2, #(RH_LARGE_OBJECT_SIZE & 0xFFFF)
        movt        r2, #(RH_LARGE_OBJECT_SIZE >> 16)
        cmp         r1, r2
        blo         New_SkipPublish
                                        ;; r0: already contains object
                                        ;; r1: already contains object size
        bl          RhpPublishObject
                                        ;; r0: function returned the passed-in object
New_SkipPublish
        COOP_PINVOKE_FRAME_EPILOG

NewOutOfMemory
        ;; This is the OOM failure path. We're going to tail-call to a managed helper that will throw
        ;; an out of memory exception that the caller of this allocator understands.

        mov         r0, r5              ; EEType pointer
        mov         r1, #0              ; Indicate that we should throw OOM.

        COOP_PINVOKE_FRAME_EPILOG_NO_RETURN

        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewObject


;; Allocate one dimensional, zero based array (SZARRAY).
;;  r0 == EEType
;;  r1 == element count
        LEAF_ENTRY RhpNewArray

        ; Compute overall allocation size (align(base size + (element size * elements), 4)).
        ; if the element count is <= 0x10000, no overflow is possible because the component
        ; size is <= 0xffff (it's an unsigned 16-bit value) and thus the product is <= 0xffff0000
        ; and the base size is only 12 bytes.
        ldrh        r2, [r0, #OFFSETOF__EEType__m_usComponentSize]
        cmp         r1, #0x10000
        bhi         ArraySizeBig
        umull       r2, r3, r2, r1
        ldr         r3, [r0, #OFFSETOF__EEType__m_uBaseSize]
        adds        r2, r3
        adds        r2, #3
ArrayAlignSize
        bic         r2, r2, #3

        ; r0 == EEType
        ; r1 == element count
        ; r2 == array size

        INLINE_GETTHREAD        r3, r12

        ;; Load potential new object address into r12.
        ldr         r12, [r3, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Determine whether the end of the object would lie outside of the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        adds        r2, r12
        bcs         RhpNewArrayRare ; if we get a carry here, the array is too large to fit below 4 GB
        ldr         r12, [r3, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r12
        bhi         RhpNewArrayRare

        ;; Reload new object address into r12.
        ldr         r12, [r3, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r3, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the new object's EEType pointer and element count.
        str         r0, [r12, #OFFSETOF__Object__m_pEEType]
        str         r1, [r12, #OFFSETOF__Array__m_Length]

        ;; Return the object allocated in r0.
        mov         r0, r12

        bx          lr

ArraySizeOverflow
        ; We get here if the size of the final array object can't be represented as an unsigned 
        ; 32-bit value. We're going to tail-call to a managed helper that will throw
        ; an overflow exception that the caller of this allocator understands.

        ; r0 holds EEType pointer already
        mov         r1, #1                  ; Indicate that we should throw OverflowException
        b           RhExceptionHandling_FailedAllocation

ArraySizeBig
        ; if the element count is negative, it's an overflow error
        cmp         r1, #0
        blt         ArraySizeOverflow
        ; now we know the element count is in the signed int range [0..0x7fffffff]
        ; overflow in computing the total size of the array size gives an out of memory exception,
        ; NOT an overflow exception
        ; we already have the component size in r2
        umull       r2, r3, r2, r1
        cbnz        r3, ArrayOutOfMemoryFinal
        ldr         r3, [r0, #OFFSETOF__EEType__m_uBaseSize]
        adds        r2, r3
        bcs         ArrayOutOfMemoryFinal
        adds        r2, #3
        bcs         ArrayOutOfMemoryFinal
        b           ArrayAlignSize
        
ArrayOutOfMemoryFinal
        ; r0 holds EEType pointer already
        mov         r1, #0                  ; Indicate that we should throw OOM.
        b           RhExceptionHandling_FailedAllocation

        LEAF_END    RhpNewArray

;; Allocate one dimensional, zero based array (SZARRAY) using the slow path that calls a runtime helper.
;;  r0 == EEType
;;  r1 == element count
;;  r2 == array size + Thread::m_alloc_context::alloc_ptr
;;  r3 == Thread
        NESTED_ENTRY RhpNewArrayRare

        COOP_PINVOKE_FRAME_PROLOG   ; r4 <- Thread

        ; Preserve the EEType in r5 and element count in r6.
        mov         r5, r0
        mov         r6, r1

        ; Recover array size by subtracting the alloc_ptr from r2.
        ldr         r0, [r4, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]
        sub         r2, r0

        mov         r7, r2          ; Save array size in r7

        mov         r0, r4          ; pThread
        mov         r1, r2          ; cbSize
        mov         r2, #0          ; uFlags
        mov         r3, r5          ; pEEType

        ; Call the rest of the allocation helper.
        ; void* RedhawkGCInterface::Alloc(Thread *pThread, UIntNative cbSize, UInt32 uFlags, EEType *pEEType)
        blx         $REDHAWKGCINTERFACE__ALLOC

        ; Test for failure (NULL return).
        cbz         r0, ArrayOutOfMemory

        ; Success, set the array's type and element count in the new object.
        str         r5, [r0, #OFFSETOF__Object__m_pEEType]
        str         r6, [r0, #OFFSETOF__Array__m_Length]

        ;; If the object is bigger than RH_LARGE_OBJECT_SIZE, we must publish it to the BGC
        movw        r2, #(RH_LARGE_OBJECT_SIZE & 0xFFFF)
        movt        r2, #(RH_LARGE_OBJECT_SIZE >> 16)
        cmp         r7, r2
        blo         NewArray_SkipPublish
                                        ;; r0: already contains object
        mov         r1, r7              ;; r1: object size
        bl          RhpPublishObject
                                        ;; r0: function returned the passed-in object
NewArray_SkipPublish

        COOP_PINVOKE_FRAME_EPILOG

ArrayOutOfMemory
        ;; This is the OOM failure path. We're going to tail-call to a managed helper that will throw
        ;; an out of memory exception that the caller of this allocator understands.

        mov         r0, r5              ;; EEType pointer
        mov         r1, #0              ;; Indicate that we should throw OOM.

        COOP_PINVOKE_FRAME_EPILOG_NO_RETURN

        EPILOG_BRANCH   RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewArrayRare

;; Allocate simple object (not finalizable, array or value type) on an 8 byte boundary.
;;  r0 == EEType
        LEAF_ENTRY RhpNewFastAlign8

        ;; r1 = GetThread(), TRASHES r2
        INLINE_GETTHREAD r1, r2

        ;; Fetch object size into r2.
        ldr         r2, [r0, #OFFSETOF__EEType__m_uBaseSize]

        ;;
        ;; r0: EEType pointer
        ;; r1: Thread pointer
        ;; r2: base size
        ;;

        ;; Load potential new object address into r3. Cache this result in r12 as well for the common case
        ;; where the allocation succeeds (r3 will be overwritten in the following bounds check).
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]
        mov         r12, r3

        ;; Check whether the current allocation context is already aligned for us.
        tst         r3, #0x7
        bne         ContextMisaligned

        ;; Determine whether the end of the object would lie outside of the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        add         r2, r3
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r3
        bhi         Alloc8Failed

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the new object's EEType pointer.
        str         r0, [r12, #OFFSETOF__Object__m_pEEType]

        ;; Return the object allocated in r0.
        mov         r0, r12

        bx          lr

ContextMisaligned
        ;; Allocation context is currently misaligned. We attempt to fix this by allocating a minimum sized
        ;; free object (which is sized such that it "flips" the alignment to a good value).

        ;; Determine whether the end of both objects would lie outside of the current allocation context. If
        ;; so, we abandon the attempt to allocate the object directly and fall back to the slow helper.
        add         r2, r3
        add         r2, #SIZEOF__MinObject
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r3
        bhi         Alloc8Failed

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the free object's EEType pointer (it's the only field we need to set, a component count of zero
        ;; is what we want).
        ldr         r2, =$G_FREE_OBJECT_EETYPE
        ldr         r2, [r2]
        str         r2, [r12, #OFFSETOF__Object__m_pEEType]

        ;; Set the new object's EEType pointer.
        str         r0, [r12, #(SIZEOF__MinObject + OFFSETOF__Object__m_pEEType)]

        ;; Return the object allocated in r0.
        add         r0, r12, #SIZEOF__MinObject

        bx          lr

Alloc8Failed
        ;; Fast allocation failed. Call slow helper with flags set to indicate an 8-byte alignment and no
        ;; finalization.
        mov         r1, #GC_ALLOC_ALIGN8
        b           RhpNewObject

        LEAF_END RhpNewFastAlign8

;; Allocate a finalizable object (by definition not an array or value type) on an 8 byte boundary.
;;  r0 == EEType
        LEAF_ENTRY RhpNewFinalizableAlign8

        mov         r1, #(GC_ALLOC_FINALIZE | GC_ALLOC_ALIGN8)
        b           RhpNewObject

        LEAF_END RhpNewFinalizableAlign8

;; Allocate a value type object (i.e. box it) on an 8 byte boundary + 4 (so that the value type payload 
;; itself is 8 byte aligned).
;;  r0 == EEType
        LEAF_ENTRY RhpNewFastMisalign

        ;; r1 = GetThread(), TRASHES r2
        INLINE_GETTHREAD r1, r2

        ;; Fetch object size into r2.
        ldr         r2, [r0, #OFFSETOF__EEType__m_uBaseSize]

        ;;
        ;; r0: EEType pointer
        ;; r1: Thread pointer
        ;; r2: base size
        ;;

        ;; Load potential new object address into r3. Cache this result in r12 as well for the common case
        ;; where the allocation succeeds (r3 will be overwritten in the following bounds check).
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]
        mov         r12, r3

        ;; Check whether the current allocation context is already aligned for us (for boxing that means the
        ;; address % 8 == 4, so the value type payload following the EEType* is actually 8-byte aligned).
        tst         r3, #0x7
        beq         BoxContextMisaligned

        ;; Determine whether the end of the object would lie outside of the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        add         r2, r3
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r3
        bhi         BoxAlloc8Failed

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the new object's EEType pointer.
        str         r0, [r12, #OFFSETOF__Object__m_pEEType]

        ;; Return the object allocated in r0.
        mov         r0, r12

        bx          lr

BoxContextMisaligned
        ;; Allocation context is currently misaligned. We attempt to fix this by allocating a minimum sized
        ;; free object (which is sized such that it "flips" the alignment to a good value).

        ;; Determine whether the end of both objects would lie outside of the current allocation context. If
        ;; so, we abandon the attempt to allocate the object directly and fall back to the slow helper.
        add         r2, r3
        add         r2, #SIZEOF__MinObject
        ldr         r3, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_limit]
        cmp         r2, r3
        bhi         BoxAlloc8Failed

        ;; Update the alloc pointer to account for the allocation.
        str         r2, [r1, #OFFSETOF__Thread__m_alloc_context__alloc_ptr]

        ;; Set the free object's EEType pointer (it's the only field we need to set, a component count of zero
        ;; is what we want).
        ldr         r2, =$G_FREE_OBJECT_EETYPE
        ldr         r2, [r2]
        str         r2, [r12, #OFFSETOF__Object__m_pEEType]

        ;; Set the new object's EEType pointer.
        str         r0, [r12, #(SIZEOF__MinObject + OFFSETOF__Object__m_pEEType)]

        ;; Return the object allocated in r0.
        add         r0, r12, #SIZEOF__MinObject

        bx          lr

BoxAlloc8Failed
        ;; Fast allocation failed. Call slow helper with flags set to indicate an 8+4 byte alignment and no
        ;; finalization.
        mov         r1, #(GC_ALLOC_ALIGN8 | GC_ALLOC_ALIGN8_BIAS)
        b           RhpNewObject

        LEAF_END RhpNewFastMisalign

;; Allocate an array on an 8 byte boundary.
;;  r0 == EEType
;;  r1 == element count
        NESTED_ENTRY RhpNewArrayAlign8

        COOP_PINVOKE_FRAME_PROLOG   ; r4 <- Thread

        ; Compute overall allocation size (base size + align((element size * elements), 4)).
        ldrh        r2, [r0, #OFFSETOF__EEType__m_usComponentSize]
        umull       r2, r3, r2, r1
        cbnz        r3, Array8SizeOverflow
        adds        r2, #3
        bcs         Array8SizeOverflow
        bic         r2, r2, #3
        ldr         r3, [r0, #OFFSETOF__EEType__m_uBaseSize]
        adds        r2, r3
        bcs         Array8SizeOverflow

        ; Preserve the EEType in r5 and element count in r6.
        mov         r5, r0
        mov         r6, r1
        mov         r7, r2                  ; Save array size in r7

        ; Call the rest of the allocation helper.
        ; void* RedhawkGCInterface::Alloc(Thread *pThread, UIntNative cbSize, UInt32 uFlags, EEType *pEEType)
        mov         r0, r4                  ; pThread
        mov         r1, r2                  ; cbSize
        mov         r2, #GC_ALLOC_ALIGN8    ; uFlags
        mov         r3, r5                  ; pEEType
        blx         $REDHAWKGCINTERFACE__ALLOC

        ; Test for failure (NULL return).
        cbz         r0, Array8OutOfMemory

        ; Success, set the array's type and element count in the new object.
        str         r5, [r0, #OFFSETOF__Object__m_pEEType]
        str         r6, [r0, #OFFSETOF__Array__m_Length]

        ;; If the object is bigger than RH_LARGE_OBJECT_SIZE, we must publish it to the BGC
        movw        r2, #(RH_LARGE_OBJECT_SIZE & 0xFFFF)
        movt        r2, #(RH_LARGE_OBJECT_SIZE >> 16)
        cmp         r7, r2
        blo         NewArray8_SkipPublish
                                        ;; r0: already contains object
        mov         r1, r7              ;; r1: object size
        bl          RhpPublishObject
                                        ;; r0: function returned the passed-in object
NewArray8_SkipPublish

        COOP_PINVOKE_FRAME_EPILOG

Array8SizeOverflow
        ; We get here if the size of the final array object can't be represented as an unsigned 
        ; 32-bit value. We're going to tail-call to a managed helper that will throw
        ; an overflow exception that the caller of this allocator understands.

        ; r0 holds EEType pointer already
        mov         r1, #1              ;; Indicate that we should throw OverflowException

        COOP_PINVOKE_FRAME_EPILOG_NO_RETURN

        ; Jump to the helper. 
        EPILOG_BRANCH   RhExceptionHandling_FailedAllocation

Array8OutOfMemory
        ; This is the OOM failure path. We're going to tail-call to a managed helper that will throw
        ; an out of memory exception that the caller of this allocator understands.

        mov         r0, r5              ;; EEType pointer
        mov         r1, #0              ;; Indicate that we should throw OOM.

        COOP_PINVOKE_FRAME_EPILOG_NO_RETURN

        ; Jump to the helper. 
        EPILOG_BRANCH   RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewArrayAlign8

        END
