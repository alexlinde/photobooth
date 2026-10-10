# ssw_tramp.s -- per-slot passthrough trampolines (x86_64, Mach-O)
# Each stub loads its slot index into r11 and jumps to common code, which saves the
# integer arg registers, calls ssw_generic_enter(self, slot, regs) for logging, restores
# the registers and tail-jumps to the original method (stack args untouched).
    .text
    .p2align 4
_ssw_tramp_common:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %r8
    pushq %r9
    subq $128, %rsp
    movdqu %xmm0, 0(%rsp)
    movdqu %xmm1, 16(%rsp)
    movdqu %xmm2, 32(%rsp)
    movdqu %xmm3, 48(%rsp)
    movdqu %xmm4, 64(%rsp)
    movdqu %xmm5, 80(%rsp)
    movdqu %xmm6, 96(%rsp)
    movdqu %xmm7, 112(%rsp)
    pushq %rax
    pushq %rax
    leaq 144(%rsp), %rdx      # -> saved r9 (regs[0]=r9 .. regs[5]=rdi)
    movq %r11, %rsi
    call _ssw_generic_enter
    movq %rax, %r11
    popq %rax
    popq %rax
    movdqu 0(%rsp), %xmm0
    movdqu 16(%rsp), %xmm1
    movdqu 32(%rsp), %xmm2
    movdqu 48(%rsp), %xmm3
    movdqu 64(%rsp), %xmm4
    movdqu 80(%rsp), %xmm5
    movdqu 96(%rsp), %xmm6
    movdqu 112(%rsp), %xmm7
    addq $128, %rsp
    popq %r9
    popq %r8
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi
    popq %rbp
    jmpq *%r11

    .p2align 3
_ssw_tramp_0:
    movq $0, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_1:
    movq $1, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_2:
    movq $2, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_3:
    movq $3, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_4:
    movq $4, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_5:
    movq $5, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_6:
    movq $6, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_7:
    movq $7, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_8:
    movq $8, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_9:
    movq $9, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_10:
    movq $10, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_11:
    movq $11, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_12:
    movq $12, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_13:
    movq $13, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_14:
    movq $14, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_15:
    movq $15, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_16:
    movq $16, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_17:
    movq $17, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_18:
    movq $18, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_19:
    movq $19, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_20:
    movq $20, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_21:
    movq $21, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_22:
    movq $22, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_23:
    movq $23, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_24:
    movq $24, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_25:
    movq $25, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_26:
    movq $26, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_27:
    movq $27, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_28:
    movq $28, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_29:
    movq $29, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_30:
    movq $30, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_31:
    movq $31, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_32:
    movq $32, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_33:
    movq $33, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_34:
    movq $34, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_35:
    movq $35, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_36:
    movq $36, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_37:
    movq $37, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_38:
    movq $38, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_39:
    movq $39, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_40:
    movq $40, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_41:
    movq $41, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_42:
    movq $42, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_43:
    movq $43, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_44:
    movq $44, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_45:
    movq $45, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_46:
    movq $46, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_47:
    movq $47, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_48:
    movq $48, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_49:
    movq $49, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_50:
    movq $50, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_51:
    movq $51, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_52:
    movq $52, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_53:
    movq $53, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_54:
    movq $54, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_55:
    movq $55, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_56:
    movq $56, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_57:
    movq $57, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_58:
    movq $58, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_59:
    movq $59, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_60:
    movq $60, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_61:
    movq $61, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_62:
    movq $62, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_63:
    movq $63, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_64:
    movq $64, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_65:
    movq $65, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_66:
    movq $66, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_67:
    movq $67, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_68:
    movq $68, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_69:
    movq $69, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_70:
    movq $70, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_71:
    movq $71, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_72:
    movq $72, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_73:
    movq $73, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_74:
    movq $74, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_75:
    movq $75, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_76:
    movq $76, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_77:
    movq $77, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_78:
    movq $78, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_79:
    movq $79, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_80:
    movq $80, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_81:
    movq $81, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_82:
    movq $82, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_83:
    movq $83, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_84:
    movq $84, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_85:
    movq $85, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_86:
    movq $86, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_87:
    movq $87, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_88:
    movq $88, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_89:
    movq $89, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_90:
    movq $90, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_91:
    movq $91, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_92:
    movq $92, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_93:
    movq $93, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_94:
    movq $94, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_95:
    movq $95, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_96:
    movq $96, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_97:
    movq $97, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_98:
    movq $98, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_99:
    movq $99, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_100:
    movq $100, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_101:
    movq $101, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_102:
    movq $102, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_103:
    movq $103, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_104:
    movq $104, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_105:
    movq $105, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_106:
    movq $106, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_107:
    movq $107, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_108:
    movq $108, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_109:
    movq $109, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_110:
    movq $110, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_111:
    movq $111, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_112:
    movq $112, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_113:
    movq $113, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_114:
    movq $114, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_115:
    movq $115, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_116:
    movq $116, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_117:
    movq $117, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_118:
    movq $118, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_119:
    movq $119, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_120:
    movq $120, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_121:
    movq $121, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_122:
    movq $122, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_123:
    movq $123, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_124:
    movq $124, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_125:
    movq $125, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_126:
    movq $126, %r11
    jmp _ssw_tramp_common
    .p2align 3
_ssw_tramp_127:
    movq $127, %r11
    jmp _ssw_tramp_common

    .section __DATA,__const
    .globl _ssw_tramp_table
    .p2align 3
_ssw_tramp_table:
    .quad _ssw_tramp_0
    .quad _ssw_tramp_1
    .quad _ssw_tramp_2
    .quad _ssw_tramp_3
    .quad _ssw_tramp_4
    .quad _ssw_tramp_5
    .quad _ssw_tramp_6
    .quad _ssw_tramp_7
    .quad _ssw_tramp_8
    .quad _ssw_tramp_9
    .quad _ssw_tramp_10
    .quad _ssw_tramp_11
    .quad _ssw_tramp_12
    .quad _ssw_tramp_13
    .quad _ssw_tramp_14
    .quad _ssw_tramp_15
    .quad _ssw_tramp_16
    .quad _ssw_tramp_17
    .quad _ssw_tramp_18
    .quad _ssw_tramp_19
    .quad _ssw_tramp_20
    .quad _ssw_tramp_21
    .quad _ssw_tramp_22
    .quad _ssw_tramp_23
    .quad _ssw_tramp_24
    .quad _ssw_tramp_25
    .quad _ssw_tramp_26
    .quad _ssw_tramp_27
    .quad _ssw_tramp_28
    .quad _ssw_tramp_29
    .quad _ssw_tramp_30
    .quad _ssw_tramp_31
    .quad _ssw_tramp_32
    .quad _ssw_tramp_33
    .quad _ssw_tramp_34
    .quad _ssw_tramp_35
    .quad _ssw_tramp_36
    .quad _ssw_tramp_37
    .quad _ssw_tramp_38
    .quad _ssw_tramp_39
    .quad _ssw_tramp_40
    .quad _ssw_tramp_41
    .quad _ssw_tramp_42
    .quad _ssw_tramp_43
    .quad _ssw_tramp_44
    .quad _ssw_tramp_45
    .quad _ssw_tramp_46
    .quad _ssw_tramp_47
    .quad _ssw_tramp_48
    .quad _ssw_tramp_49
    .quad _ssw_tramp_50
    .quad _ssw_tramp_51
    .quad _ssw_tramp_52
    .quad _ssw_tramp_53
    .quad _ssw_tramp_54
    .quad _ssw_tramp_55
    .quad _ssw_tramp_56
    .quad _ssw_tramp_57
    .quad _ssw_tramp_58
    .quad _ssw_tramp_59
    .quad _ssw_tramp_60
    .quad _ssw_tramp_61
    .quad _ssw_tramp_62
    .quad _ssw_tramp_63
    .quad _ssw_tramp_64
    .quad _ssw_tramp_65
    .quad _ssw_tramp_66
    .quad _ssw_tramp_67
    .quad _ssw_tramp_68
    .quad _ssw_tramp_69
    .quad _ssw_tramp_70
    .quad _ssw_tramp_71
    .quad _ssw_tramp_72
    .quad _ssw_tramp_73
    .quad _ssw_tramp_74
    .quad _ssw_tramp_75
    .quad _ssw_tramp_76
    .quad _ssw_tramp_77
    .quad _ssw_tramp_78
    .quad _ssw_tramp_79
    .quad _ssw_tramp_80
    .quad _ssw_tramp_81
    .quad _ssw_tramp_82
    .quad _ssw_tramp_83
    .quad _ssw_tramp_84
    .quad _ssw_tramp_85
    .quad _ssw_tramp_86
    .quad _ssw_tramp_87
    .quad _ssw_tramp_88
    .quad _ssw_tramp_89
    .quad _ssw_tramp_90
    .quad _ssw_tramp_91
    .quad _ssw_tramp_92
    .quad _ssw_tramp_93
    .quad _ssw_tramp_94
    .quad _ssw_tramp_95
    .quad _ssw_tramp_96
    .quad _ssw_tramp_97
    .quad _ssw_tramp_98
    .quad _ssw_tramp_99
    .quad _ssw_tramp_100
    .quad _ssw_tramp_101
    .quad _ssw_tramp_102
    .quad _ssw_tramp_103
    .quad _ssw_tramp_104
    .quad _ssw_tramp_105
    .quad _ssw_tramp_106
    .quad _ssw_tramp_107
    .quad _ssw_tramp_108
    .quad _ssw_tramp_109
    .quad _ssw_tramp_110
    .quad _ssw_tramp_111
    .quad _ssw_tramp_112
    .quad _ssw_tramp_113
    .quad _ssw_tramp_114
    .quad _ssw_tramp_115
    .quad _ssw_tramp_116
    .quad _ssw_tramp_117
    .quad _ssw_tramp_118
    .quad _ssw_tramp_119
    .quad _ssw_tramp_120
    .quad _ssw_tramp_121
    .quad _ssw_tramp_122
    .quad _ssw_tramp_123
    .quad _ssw_tramp_124
    .quad _ssw_tramp_125
    .quad _ssw_tramp_126
    .quad _ssw_tramp_127
