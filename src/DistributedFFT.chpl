/* Documentation for DistributedFFT */
prototype module DistributedFFT {

  use BlockDist;
  use ChapelLocks;
  use AllLocalesBarriers;
  use ReplicatedVar;
  use RangeChunk;
  use FFTW;
  use FFTW.C_FFTW;
  use FFT_Timers;
  require "npFFTW.h";

  config const useElegant=false;

  proc deinit() {
    cleanup();
  }

  pragma "locale private"
  var fftw_planner_lock$ : chpl_LocalSpinlock;

  enum FFTtype {DFT, R2R};

  /* fftw_plan fftw_plan_many_dft(int rank, const int *n, int howmany, */
  /*                              fftw_complex *in, const int *inembed, */
  /*                              int istride, int idist, */
  /*                              fftw_complex *out, const int *onembed, */
  /*                              int ostride, int odist, */
  /*                              int sign, unsigned flags); */
  /* fftw_plan fftw_plan_many_r2r(int rank, const int *n, int howmany, */
  /*                              double *in, const int *inembed, */
  /*                              int istride, int idist, */
  /*                              double *out, const int *onembed, */
  /*                              int ostride, int odist, */
  /*                              const fftw_r2r_kind *kind, unsigned flags); */
  // https://github.com/chapel-lang/chapel/issues/13319
  pragma "default intent is ref"
  record FFTWplan {
    param ftType : FFTtype;
    var plan : fftw_plan;
    var tt : TimeTracker;

    // Mimic the advanced interface 
    proc init(param ftType1 : FFTtype, args ...?k) {
      ftType = ftType1;
      this.complete();
      fftw_planner_lock$.lock();
      select ftType {
          when FFTtype.DFT do plan = fftw_plan_many_dft((...args));
          when FFTtype.R2R do plan = fftw_plan_many_r2r((...args));
        }
      fftw_planner_lock$.unlock();
    }

    proc deinit() {
      fftw_planner_lock$.lock();
      destroy_plan(plan);
      fftw_planner_lock$.unlock();
    }

    proc execute() {
      tt.start();
      FFTW.execute(plan);
      tt.stop(TimeStages.Execute);
    }

    proc execute(arr1 : c_ptr(?T), arr2 : c_ptr(T)) {
      select ftType {
          when FFTtype.DFT do fftw_execute_dft(plan, arr1, arr2);
          when FFTtype.R2R do fftw_execute_r2r(plan, arr1, arr2);
        }
    }

    inline proc execute(ref arr1 : ?T, ref arr2 : T) where (!isAnyCPtr(T)) {
      var elt1 = c_ptrTo(arr1);
      var elt2 = c_ptrTo(arr2);
      select ftType {
          when FFTtype.DFT do fftw_execute_dft(plan, elt1, elt2);
          when FFTtype.R2R do fftw_execute_r2r(plan, elt1, elt2);
        }
    }

    inline proc execute(ref arr1 : ?T) where (!isAnyCPtr(T)) {
      var elt1 = c_ptrTo(arr1);
      select ftType {
          when FFTtype.DFT do fftw_execute_dft(plan, elt1, elt1);
          when FFTtype.R2R do fftw_execute_r2r(plan, elt1, elt1);
        }
    }


    proc isValid : bool {
      extern proc isNullPlan(plan : fftw_plan) : c_int;
      return isNullPlan(plan)==0;
    }
  }

  /* Convenience constructor for grids */
  proc newSlabDom(dom: domain) where isRectangularDom(dom) {
    if dom.rank !=3 then compilerError("The domain must be 3D");
    const targetLocales = reshape(Locales, {0.. #numLocales, 0..0, 0..0});
    return dom dmapped Block(boundingBox=dom, targetLocales=targetLocales);
  }

  proc newSlabDom(sz) where isHomogeneousTupleType(sz.type) {
    var tup : (sz.size)*range;
    for param ii in 1..sz.size do tup(ii) = 0.. #sz(ii);
    return newSlabDom({(...tup)});
  }

  proc doFFT_Transposed(param ftType : FFTtype,
                        src: [?SrcDom] ?T,
                        dest : [?DestDom] T,
                        signOrKind) {
    if (useElegant) {
      doFFT_Transposed_Elegant(ftType, src, dest, signOrKind);
    } else {
      doFFT_Transposed_Performant(ftType, src, dest, signOrKind);
    }
  }


  /* FFT.

     Stores the FFT in Dst transposed (xyz -> yxz).
   */
  proc doFFT_Transposed_Elegant(param ftType : FFTtype,
                                Src: [?SrcDom] ?T,
                                Dst : [?DstDom] T,
                                signOrKind) {
    // Sanity checks
    if SrcDom.rank != 3 || DstDom.rank != 3 then compilerError("Code is designed for 3D arrays only");
    if SrcDom.dim(1) != DstDom.dim(2) then halt("Mismatched x-y ranges");
    if SrcDom.dim(2) != DstDom.dim(1) then halt("Mismatched y-x ranges");
    if SrcDom.dim(3) != DstDom.dim(3) then halt("Mismatched z ranges");

    coforall loc in Locales do on loc {
      const (xSrc, ySrc, zSrc) = SrcDom.localSubdomain().dims();
      const (yDst, xDst, _) = DstDom.localSubdomain().dims();

      // Set up FFTW plans
      var xPlan = setup1DPlan(T, ftType, xDst.size, zSrc.size, signOrKind, FFTW_MEASURE);
      var yPlan = setup1DPlan(T, ftType, ySrc.size, zSrc.size, signOrKind, FFTW_MEASURE);
      var zPlan = setup1DPlan(T, ftType, zSrc.size, 1, signOrKind, FFTW_MEASURE);

      // Use temp work array to avoid overwriting the Src array
      var myplane : [{0..0, ySrc, zSrc}] T;

      for ix in xSrc {
        // Copy source to temp array
        myplane = Src[{ix..ix, ySrc, zSrc}]; // Ideal
        // [iy in ySrc] myplane[{0..0, iy..iy, zSrc}] = Src[{ix..ix, iy..iy, zSrc}]; // Better perf

        // Y-transform
        forall iz in zSrc {
          yPlan.execute(myplane[0, ySrc.first, iz]);
        }

        // Z-transform, offset to reduce comm congestion/collision
        forall iy in offset(ySrc) {
          zPlan.execute(myplane[0, iy, zSrc.first]);
          // Transpose data into Dst
          Dst[{iy..iy, ix..ix, zSrc}] = myplane[{0..0, iy..iy, zSrc}]; // Ideal
          //remotePut(Dst[iy, ix , zSrc.first], myplane[0, iy, zSrc.first], zSrc.size*numBytes(T));  // Better perf
        }
      }

      // Wait until all communication is complete
      allLocalesBarrier.barrier();

      // X-transform
      forall (iy, iz) in {yDst, zSrc} {
        xPlan.execute(Dst[iy, xDst.first, iz]);
      }
    }
  }


  /* FFT.

     Stores the FFT in Dst transposed (xyz -> yxz).
   */
  proc doFFT_Transposed_Performant(param ftType : FFTtype,
                                   Src: [?SrcDom] ?T,
                                   Dst : [?DstDom] T,
                                   signOrKind) {
    // Sanity checks
    if SrcDom.rank != 3 || DstDom.rank != 3 then compilerError("Code is designed for 3D arrays only");
    if SrcDom.dim(1) != DstDom.dim(2) then halt("Mismatched x-y ranges");
    if SrcDom.dim(2) != DstDom.dim(1) then halt("Mismatched y-x ranges");
    if SrcDom.dim(3) != DstDom.dim(3) then halt("Mismatched z ranges");

    coforall loc in Locales do on loc {
      const (xSrc, ySrc, zSrc) = SrcDom.localSubdomain().dims();
      const (yDst, xDst, _) = DstDom.localSubdomain().dims();
      const myLineSize = zSrc.size*numBytes(T);

      // Setup FFTW plans, x/y are batched so we need a different batch size
      // for when zSrc doesn't evenly split into numTasks
      const numTasks = min(here.maxTaskPar, zSrc.size);
      const (batchSizeSm, batchSizeLg) = (zSrc.size/numTasks, zSrc.size/numTasks+1);
      var yPlanSm = setupPlanColumns(T, ftType, {ySrc, zSrc}, batchSizeSm, signOrKind, FFTW_MEASURE);
      var yPlanLg = setupPlanColumns(T, ftType, {ySrc, zSrc}, batchSizeLg, signOrKind, FFTW_MEASURE);
      var xPlanSm = setupPlanColumns(T, ftType, {xDst, zSrc}, batchSizeSm, signOrKind, FFTW_MEASURE);
      var xPlanLg = setupPlanColumns(T, ftType, {xDst, zSrc}, batchSizeLg,  signOrKind, FFTW_MEASURE);
      var zPlan = setup1DPlan(T, ftType, zSrc.size, 1, signOrKind, FFTW_MEASURE);

      // Use temp work array to avoid overwriting the Src array
      var myplane : [{0..0, ySrc, zSrc}] T;

      forall iy in ySrc {
        copy(myplane[0, iy, zSrc.first], Src[xSrc.first, iy, zSrc.first], myLineSize);
      }

      for ix in xSrc {
        // Y-transform
        forall myzRange in batchedRange(zSrc, numTasks) {
          ref elt = myplane[0, ySrc.first, myzRange.first];
          if myzRange.size == batchSizeSm then yPlanSm.execute(elt);
                                          else yPlanLg.execute(elt);
        }

        // Z-transform, offset to reduce comm congestion/collision
        forall iy in offset(ySrc) {
          zPlan.execute(myplane[0, iy, zSrc.first]);
          // This is the transpose step
          copy(Dst[iy, ix, zSrc.first], myplane[0, iy, zSrc.first], myLineSize);
          // If not last slice, copy over
          if (ix != xSrc.last) {
            copy(myplane[0, iy, zSrc.first], Src[ix+1, iy, zSrc.first], myLineSize);
          }
        }
      }

      // Wait until all communication is complete
      allLocalesBarrier.barrier();

      // X-transform
      forall myzRange in batchedRange(zSrc, numTasks) {
        for iy in yDst {
          ref elt = Dst[iy, xDst.first, myzRange.first];
          if myzRange.size == batchSizeSm then xPlanSm.execute(elt);
                                          else xPlanLg.execute(elt);
        }
      }
    }
  }

  iter offset(r: range) { halt("Serial offset not implemented"); }
  iter offset(param tag: iterKind, r: range) where (tag==iterKind.standalone) {
    forall i in r + (r.size/numLocales * here.id) do {
      yield i % r.size + r.first;
    }
  }

  proc copy(ref dst, const ref src, numBytes: int) {
    if dst.locale.id == here.id {
      __primitive("chpl_comm_get", dst, src.locale.id, src, numBytes.safeCast(size_t));
    } else if src.locale.id == here.id {
      __primitive("chpl_comm_put", src, dst.locale.id, dst, numBytes.safeCast(size_t));
    } else {
      halt("Remote src and remote dst not yet supported");
    }
  }

  iter batchedRange(r : range, numTasks) {
    halt("Serial iterator not implemented");
  }

  iter batchedRange(param tag : iterKind, r : range, numTasks)
    where (tag==iterKind.standalone)
  {
    coforall chunk in chunks(r, numTasks) {
      yield chunk;
    }
  }


  // Set up 1D in-place plans
  proc setup1DPlan(type arrType, param ftType : FFTtype, nx : int, strideIn : int, signOrKind, in flags : c_uint) {
    // Pull signOrKind locally since this may be an array
    // we need to take a pointer to.
    var mySignOrKind = signOrKind;
    var arg0 : _signOrKindType(ftType);
    select ftType {
        when FFTtype.R2R do arg0 = c_ptrTo(mySignOrKind);
        when FFTtype.DFT do arg0 = mySignOrKind;
      }

    // Define a dummy array
    var arr : [0.. #(nx*strideIn)] arrType;

    // Write down all the parameters explicitly
    var howmany = 1 : c_int;
    var nn : c_array(c_int, 1);
    nn[0] = nx : c_int;
    var nnp = c_ptrTo(nn[0]);
    var rank = 1 : c_int;
    var stride = strideIn  : c_int;
    var idist = 0 : c_int;
    var arr0 = c_ptrTo(arr);
    flags = flags | FFTW_UNALIGNED;
    return new FFTWplan(ftType, rank, nnp, howmany, arr0,
                        nnp, stride, idist,
                        arr0, nnp, stride, idist,
                        arg0, flags);
  }

  // Set up many 1D in place plans
  proc setupPlanColumns(type arrType, param ftType : FFTtype, dom : domain(2), numTransforms : int, signOrKind, in flags : c_uint) {
    // Pull signOrKind locally since this may be an array
    // we need to take a pointer to.
    var mySignOrKind = signOrKind;
    var arg0 : _signOrKindType(ftType);
    select ftType {
        when FFTtype.R2R do arg0 = c_ptrTo(mySignOrKind);
        when FFTtype.DFT do arg0 = mySignOrKind;
      }

    // Define a dummy array
    var arr : [dom] arrType;

    // Write down all the parameters explicitly
    var howmany = numTransforms : c_int;
    var nn : c_array(c_int, 1);
    nn[0] = dom.dim(1).size : c_int;
    var nnp = c_ptrTo(nn[0]);
    var rank = 1 : c_int;
    var stride = dom.dim(2).size  : c_int;
    var idist = 1 : c_int;
    var arr0 = c_ptrTo(arr);
    flags = flags | FFTW_UNALIGNED;
    return new FFTWplan(ftType, rank, nnp, howmany, arr0,
                        nnp, stride, idist,
                        arr0, nnp, stride, idist,
                        arg0, flags);
  }



  // I could not combine these, so keep them separate for now.
  private proc _signOrKindType(param ftType : FFTtype) type
    where (ftType==FFTtype.DFT) {
    return c_int;
  }
  private proc _signOrKindType(param ftType : FFTtype) type
    where (ftType==FFTtype.R2R) {
    return c_ptr(fftw_r2r_kind);
  }


  module FFT_Timers {
    use Time;
    // Time the various FFT steps.
    config const timeTrackFFT=false;

    enum TimeStages {X, YZ, Execute, Memcpy, Comms};
    const stageDomain = {TimeStages.X..TimeStages.Comms};
    private var _globalTimeArr : [stageDomain] atomic real;

    resetTimers();

    proc deinit() {
      if timeTrackFFT then printTimers();
    }

    proc resetTimers() {
      for stage in _globalTimeArr do stage.write(0.0);
    }

    proc printTimers() {
      writeln("--------- Timings ---------------");
      for stage in TimeStages {
        writef("Time for %s : %10.2dr\n",stage:string, _globalTimeArr[stage].read());
      }
      writeln("---------------------------------");
    }


    record TimeTracker {
      var tt : Timer();
      var arr : [stageDomain] real;

      proc deinit() {
        if timeTrackFFT {
          for istage in arr.domain {
            _globalTimeArr[istage].add(arr[istage]);
          }
        }
      }

      proc start() {
        if timeTrackFFT {
          tt.clear(); tt.start();
        }
      }

      proc stop(stage) {
        if timeTrackFFT {
          tt.stop();
          arr[stage] += tt.elapsed();
        }
      }
    }

  }


  // End of module
}
