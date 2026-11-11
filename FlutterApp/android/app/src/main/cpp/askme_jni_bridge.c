#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* -------------------------------------------------------------------------
 * C ABI declarations for the NativeAOT shared library
 * (libaskme_android_host.so compiled from AskMe.AndroidHost)
 * --------------------------------------------------------------------- */

extern int   askme_backend_api_version(void);
extern int   askme_backend_initialize(void);
extern int64_t askme_backend_start_request(void);
extern int   askme_backend_cancel_request(int64_t request_id);
extern int   askme_backend_complete_request(int64_t request_id);

/*
 * askme_backend_process_document
 *   requestId     - active request id
 *   doc_bytes     - raw document bytes
 *   doc_length    - byte count
 *   file_name_utf8 - UTF-8 file name (with extension)
 *   file_name_len  - byte count of file name
 *   out_chunk_count - receives chunk count on success
 * Returns: 0=ok, 1=bad args, 2=wrong req, 3=bad format, 4=error, 5=too large
 */
extern int   askme_backend_process_document(
    int64_t  request_id,
    const uint8_t *doc_bytes, int doc_length,
    const uint8_t *file_name_utf8, int file_name_len,
    int *out_chunk_count);

/*
 * askme_backend_retrieve_chunks
 *   requestId       - active request id
 *   question_utf8   - UTF-8 question bytes
 *   question_len    - byte count
 *   out_buffer      - caller-allocated output buffer
 *   out_buffer_size - capacity of out_buffer
 *   out_written     - receives bytes written (excl. null terminator)
 * Returns: 0=ok, 1=bad args, 2=wrong req, 3=no doc, 6=buf too small, 7=bad utf8
 */
extern int   askme_backend_retrieve_chunks(
    int64_t   request_id,
    const uint8_t *question_utf8, int question_len,
    uint8_t  *out_buffer, int out_buffer_size,
    int      *out_written);

/* -------------------------------------------------------------------------
 * JNI wrappers — existing
 * --------------------------------------------------------------------- */

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendApiVersion(JNIEnv *env, jobject thiz) {
    (void) env; (void) thiz;
    return (jint) askme_backend_api_version();
}

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendInitialize(JNIEnv *env, jobject thiz) {
    (void) env; (void) thiz;
    return (jint) askme_backend_initialize();
}

JNIEXPORT jlong JNICALL
Java_com_example_askme_MainActivity_nativeBackendStartRequest(JNIEnv *env, jobject thiz) {
    (void) env; (void) thiz;
    return (jlong) askme_backend_start_request();
}

JNIEXPORT jboolean JNICALL
Java_com_example_askme_MainActivity_nativeBackendCancelRequest(JNIEnv *env, jobject thiz, jlong request_id) {
    (void) env; (void) thiz;
    return askme_backend_cancel_request((int64_t) request_id) == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_example_askme_MainActivity_nativeBackendCompleteRequest(JNIEnv *env, jobject thiz, jlong request_id) {
    (void) env; (void) thiz;
    return askme_backend_complete_request((int64_t) request_id) == 1 ? JNI_TRUE : JNI_FALSE;
}

/* -------------------------------------------------------------------------
 * JNI wrappers — document processing
 *
 * Kotlin signature:
 *   private external fun nativeBackendProcessDocument(
 *       requestId: Long, docBytes: ByteArray, fileNameBytes: ByteArray
 *   ): IntArray   // [returnCode, chunkCount]
 * --------------------------------------------------------------------- */

JNIEXPORT jintArray JNICALL
Java_com_example_askme_MainActivity_nativeBackendProcessDocument(
    JNIEnv *env, jobject thiz,
    jlong   request_id,
    jbyteArray doc_bytes_arr,
    jbyteArray file_name_arr)
{
    (void) thiz;

    /* Allocate result array: [0]=returnCode, [1]=chunkCount */
    jintArray result = (*env)->NewIntArray(env, 2);
    if (!result) return NULL;
    jint buf[2] = {1, 0}; /* default: invalid args */

    if (!doc_bytes_arr || !file_name_arr) goto done;

    jsize doc_len  = (*env)->GetArrayLength(env, doc_bytes_arr);
    jsize name_len = (*env)->GetArrayLength(env, file_name_arr);
    if (doc_len <= 0 || name_len <= 0) goto done;

    jbyte *doc_ptr  = (*env)->GetByteArrayElements(env, doc_bytes_arr,  NULL);
    jbyte *name_ptr = (*env)->GetByteArrayElements(env, file_name_arr, NULL);

    int chunk_count = 0;
    int rc = askme_backend_process_document(
        (int64_t) request_id,
        (const uint8_t *) doc_ptr,  (int) doc_len,
        (const uint8_t *) name_ptr, (int) name_len,
        &chunk_count);

    (*env)->ReleaseByteArrayElements(env, doc_bytes_arr,  doc_ptr,  JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, file_name_arr, name_ptr, JNI_ABORT);

    buf[0] = (jint) rc;
    buf[1] = (jint) chunk_count;

done:
    (*env)->SetIntArrayRegion(env, result, 0, 2, buf);
    return result;
}

/* -------------------------------------------------------------------------
 * JNI wrappers — chunk retrieval (RAG)
 *
 * Kotlin signature:
 *   private external fun nativeBackendRetrieveChunks(
 *       requestId: Long, questionBytes: ByteArray, bufferSize: Int
 *   ): ByteArray?   // null on alloc failure; [0..3]=int returnCode LE, [4..]=UTF-8 context
 * --------------------------------------------------------------------- */

JNIEXPORT jbyteArray JNICALL
Java_com_example_askme_MainActivity_nativeBackendRetrieveChunks(
    JNIEnv  *env, jobject thiz,
    jlong    request_id,
    jbyteArray question_arr,
    jint     buffer_size)
{
    (void) thiz;

    if (!question_arr || buffer_size <= 0) return NULL;

    jsize q_len = (*env)->GetArrayLength(env, question_arr);
    if (q_len <= 0) return NULL;

    /* Allocate native output buffer */
    uint8_t *out_buf = (uint8_t *) malloc((size_t) buffer_size);
    if (!out_buf) return NULL;

    jbyte *q_ptr = (*env)->GetByteArrayElements(env, question_arr, NULL);
    int written  = 0;
    int rc = askme_backend_retrieve_chunks(
        (int64_t) request_id,
        (const uint8_t *) q_ptr, (int) q_len,
        out_buf, (int) buffer_size,
        &written);
    (*env)->ReleaseByteArrayElements(env, question_arr, q_ptr, JNI_ABORT);

    /*
     * Result ByteArray layout: [0..3] = returnCode as little-endian int32,
     *                          [4..4+written-1] = UTF-8 context bytes.
     */
    int total = 4 + (rc == 0 ? written : 0);
    jbyteArray result = (*env)->NewByteArray(env, (jsize) total);
    if (!result) { free(out_buf); return NULL; }

    /* Write returnCode LE */
    jbyte rc_bytes[4];
    rc_bytes[0] = (jbyte)( rc        & 0xff);
    rc_bytes[1] = (jbyte)((rc >>  8) & 0xff);
    rc_bytes[2] = (jbyte)((rc >> 16) & 0xff);
    rc_bytes[3] = (jbyte)((rc >> 24) & 0xff);
    (*env)->SetByteArrayRegion(env, result, 0, 4, rc_bytes);

    if (rc == 0 && written > 0) {
        (*env)->SetByteArrayRegion(env, result, 4, (jsize) written, (const jbyte *) out_buf);
    }

    free(out_buf);
    return result;
}
