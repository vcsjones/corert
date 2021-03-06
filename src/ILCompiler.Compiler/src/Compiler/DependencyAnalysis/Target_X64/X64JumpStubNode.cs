// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using ILCompiler.DependencyAnalysis;
using ILCompiler.DependencyAnalysis.X64;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace ILCompiler.DependencyAnalysis
{
    /// <summary>
    /// X64 specific portions of JumpStubNode
    /// </summary>
    public partial class JumpStubNode
    {
        protected override void EmitCode(NodeFactory factory, ref X64Emitter encoder, bool relocsOnly)
        {
            encoder.EmitJMP(_target);
        }
    }
}
