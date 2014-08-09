This project is a multi-core GPGPU (general purpose graphics processing unit) core, implemented in SystemVerilog. 
Documentation is available here: https://github.com/jbush001/GPGPU/wiki.  
Pull requests/contributions are welcome.

## Required Tools/Libraries
* Host toolchain: GCC 4.7+ or Clang 4.2+
* Python 2.7
* Verilator (3.862 or later) (http://www.veripool.org/projects/verilator/wiki/Installing)
* libreadline-dev (MacOS already has this; may need to install on Linux)
* C/C++ cross compiler toolchain targeting this architecture (https://github.com/jbush001/LLVM-GPGPU)

On Ubuntu, most of these (with the exception of the cross compiler) can be be installed using the package manager: sudo apt-get install verilator gcc g++ python libreadline-dev. However, if you are not on a recent distribution, they may be too old, in which case you'll need to build them manually.

I've run this on Linux and MacOS X (Lion). I have not tested this on Windows, although I would expect it to work in Cygwin, potentially with some modifications.

### To run on FPGA
* USB Blaster JTAG tools (https://github.com/swetland/jtag)
* libusb-1.0 (required for above)
* Quartus II FPGA design software (http://www.altera.com/products/software/quartus-ii/web-edition/qts-we-index.html)

### Optional:
* Emacs v23.2+, for AUTOWIRE/AUTOINST (Note that this doesn't require using Emacs as an editor. Using 'make autos' in the rtl/v1/ directory will run this operation in batch mode if the tools are installed).
* Java (J2SE 6+) for visualizer app 
* GTKWave (or similar) for analyzing waveform files

## Running in Verilog simulation

### To build tools and verilog models:

First, you must download and build the LLVM toolchain from here: https://github.com/jbush001/LLVM-GPGPU. The README file in the root directory provides instructions.

Once this is done, from the top directory of this project:

    make

_By default, everything will use the version 1 microarchitecture located in rtl/v1. They can be made to use the v2 
microarchitecture (which is still in development) by setting the UARCH_VERSION environment variable to 'v2'_

### Running verification tests (in Verilog simulation)

From the top directory: 

    make test

### Running 3D Engine (in Verilog simulation)

    cd firmware/3D-renderer
    make verirun

(output image stored in fb.bmp)

## Running on FPGA
This runs on Terasic's DE2-115 evaluation board. These instructions are for Linux only.

- Build USB blaster command line tools (https://github.com/swetland/jtag) 
 * Update your PATH environment variable to point the directory where you built the tools.  
 * Create a file /etc/udev/rules.d/99-custom.rules and add the line: ATTRS{idVendor}=="09fb" , MODE="0660" , GROUP="plugdev" 
- Build the bitstream (ensure quartus binary directory is in your PATH, by default installed in ~/altera/13.1/quartus/bin/)
<pre>
    cd rtl/v1/fpga/de2-115
    make
</pre>
- The FPGA board should be in JTAG mode by setting JP3 appropriately.
- Load the bitstream onto the board.  This is loading into configuration RAM on the FPGA.  It will be lost if the FPGA is powered off.
- Note that you may need to run the GUI programmer once and select the device to create the chain definition file (.CDF)
<pre>
    make program 
</pre>
- Load program into memory and execute it using the runit script as below.   The script assembles the source and uses the jload command to transfer the program over the USB blaster cable that was used to load the bitstream.  jload will automatically reset the processor as a side effect, so the bitstream does not need to be reloaded each time.
<pre>
cd ../../../tests/fpga/blinky
./runit.sh
</pre>

