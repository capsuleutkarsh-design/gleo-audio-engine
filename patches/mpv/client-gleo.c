
/* Gleo: export the gleoscope tap (FFmpeg's libavfilter/af_gleoscope.c, patched in
 * by the Gleo audio engine build) so the player can read the newest samples. */
int ff_gleoscope_read(float *out, int frames, int ago, double *info);
MPV_EXPORT int gleo_scope_read(float *out, int frames, int ago, double *info);
int gleo_scope_read(float *out, int frames, int ago, double *info)
{
    return ff_gleoscope_read(out, frames, ago, info);
}
