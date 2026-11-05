#include <jni.h>

extern int askme_backend_api_version(void);
extern int askme_backend_initialize(void);

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendApiVersion(JNIEnv *env, jobject thiz) {
    (void) env;
    (void) thiz;
    return (jint) askme_backend_api_version();
}

JNIEXPORT jint JNICALL
Java_com_example_askme_MainActivity_nativeBackendInitialize(JNIEnv *env, jobject thiz) {
    (void) env;
    (void) thiz;
    return (jint) askme_backend_initialize();
}

#include <stdint.h>

extern int64_t askme_backend_start_request(void);
extern int askme_backend_cancel_request(int64_t request_id);
extern int askme_backend_complete_request(int64_t request_id);

JNIEXPORT jlong JNICALL
Java_com_example_askme_MainActivity_nativeBackendStartRequest(JNIEnv *env, jobject thiz) {
    (void) env;
    (void) thiz;
    return (jlong) askme_backend_start_request();
}

JNIEXPORT jboolean JNICALL
Java_com_example_askme_MainActivity_nativeBackendCancelRequest(JNIEnv *env, jobject thiz, jlong request_id) {
    (void) env;
    (void) thiz;
    return askme_backend_cancel_request((int64_t) request_id) == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_example_askme_MainActivity_nativeBackendCompleteRequest(JNIEnv *env, jobject thiz, jlong request_id) {
    (void) env;
    (void) thiz;
    return askme_backend_complete_request((int64_t) request_id) == 1 ? JNI_TRUE : JNI_FALSE;
}
