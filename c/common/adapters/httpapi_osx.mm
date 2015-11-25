// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <foundation/foundation.h>
#include <functional>
#include <mutex>
#include <condition_variable>
#include "httpapi.h"
#include "iot_logging.h"
#include "buffer_.h"

DEFINE_ENUM_STRINGS(HTTPAPI_RESULT, HTTPAPI_RESULT_VALUES);

std::mutex g_mutex;
std::condition_variable_any g_ready;

//@interface SessionDelegate : NSObject< NSURLSessionDelegate, NSURLSessionDataDelegate >
//{
//@public
//    NSMutableData* connectionData;
//}
//@end
//
//@implementation SessionDelegate
//-(void) URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
//{
//    [connectionData appendData: data ];
//}
//-(void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
//{
//    if( error)
//    {
//        NSLog(@"Errored out: %@", error.description );
//    }
//    g_ready.notify_all();
//}
//@end

struct HTTP_HANDLE_OSX
{
    NSURLSessionConfiguration* config;
//    SessionDelegate* delegate;
    NSURLSession* session;
    NSURLSessionDataTask* task;
    NSString* hostName;
    NSOperationQueue* queue;
    unsigned int code;
};


HTTPAPI_RESULT HTTPAPI_Init(void)
{
    return HTTPAPI_OK;
}

/** @brief  Free resources allocated in ::HTTPAPI_Init. */
void HTTPAPI_Deinit(void)
{

}

/**
 * @brief   Creates an HTTPS connection to the host specified by the @p
 *          hostName parameter.
 *
 * @param   hostName    Name of the host.
 *
 *          This function returns a handle to the newly created connection.
 *          You can use the handle in subsequent calls to execute specific
 *          HTTP calls using ::HTTPAPI_ExecuteRequest.
 * 
 * @return  A @c HTTP_HANDLE to the newly created connection or @c NULL in
 *          case an error occurs.
 */
HTTP_HANDLE HTTPAPI_CreateConnection(const char* hostName)
{
    HTTP_HANDLE_OSX* osxHandle = new HTTP_HANDLE_OSX();
    
    osxHandle->config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
//    osxHandle->delegate = [[SessionDelegate alloc] init];
    osxHandle->queue = [[NSOperationQueue alloc] init];
    
    osxHandle->session = [NSURLSession sessionWithConfiguration: osxHandle->config delegate: nil delegateQueue: osxHandle->queue ];
    osxHandle->hostName = [NSString stringWithUTF8String: hostName];

    return (HTTP_HANDLE)osxHandle;
}

/**
 * @brief   Closes a connection created with ::HTTPAPI_CreateConnection.
 *
 * @param   handle  The handle to the HTTP connection created via ::HTTPAPI_CreateConnection.
 *                  
 *          All resources allocated by ::HTTPAPI_CreateConnection should be
 *          freed in ::HTTPAPI_CloseConnection.
 */
void HTTPAPI_CloseConnection(HTTP_HANDLE handle)
{
//    HTTP_HANDLE_OSX* osxHandle = (HTTP_HANDLE_OSX*)handle;
//    
//    [osxHandle->session finishTasksAndInvalidate];
//    delete osxHandle;
}

HTTPAPI_RESULT validateExecRequestParms( HTTP_HANDLE_OSX* osxHandle,
                                        const char* relativePath,
                                        const unsigned char* content,
                                        size_t contentLength)
{
    if ((osxHandle == NULL) ||
        (relativePath == NULL) ||
        ((content == NULL) && (contentLength > 0))
        )
    {
        LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, HTTPAPI_INVALID_ARG));
        return HTTPAPI_INVALID_ARG;
    }
    
    if( osxHandle->hostName == nil ||
       osxHandle->hostName.length <= 0)
    {
        LogError("(hostName is nil = %s)\r\n", "" );
        return HTTPAPI_INVALID_ARG;
    }
    
    return HTTPAPI_OK;
}

void createTaskWithData(HTTP_HANDLE_OSX* osxHandle,
                        NSMutableURLRequest* request,
                        const unsigned char* content,
                        size_t contentLength,
                        void (^handler)(NSData *data,
                          NSURLResponse *response,
                          NSError *error) )
{
    if( !content || (contentLength == 0 ))
        return;

    NSData* data = [NSData dataWithBytes: content length: contentLength];
    osxHandle->task = [osxHandle->session uploadTaskWithRequest: request fromData: data completionHandler: handler];
}

NSMutableURLRequest* createURLRequest( HTTP_HANDLE_OSX* osxHandle,
                                      const char* relativePath,
                                      HTTPAPI_REQUEST_TYPE requestType,
                                      const unsigned char* content,
                                      size_t contentLength)
{
    if( osxHandle == nil )
        return nil;
    
    if( relativePath == NULL)
    {
        LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, HTTPAPI_INVALID_ARG));
        return nil;
    }
    
    NSString* base = @"https://";
    base = [base stringByAppendingString: osxHandle->hostName];
    NSURL* url                      = [NSURL URLWithString: base];
    url                             = [NSURL URLWithString: [NSString stringWithUTF8String:relativePath] relativeToURL: url];
    return [[NSMutableURLRequest alloc] initWithURL: url];
}

HTTPAPI_RESULT setHeaderValues( HTTP_HANDLE_OSX* osxHandle, HTTP_HEADERS_HANDLE httpHeadersHandle )
{
    size_t headersCount = 0L;
    size_t i;
    HTTPAPI_RESULT result = HTTPAPI_OK;
    
    if (HTTPHeaders_GetHeaderCount(httpHeadersHandle, &headersCount) != HTTP_HEADERS_OK)
    {
        LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, HTTPAPI_INVALID_ARG));
        return HTTPAPI_INVALID_ARG;
    }
    
    if( headersCount == 0 )
        return HTTPAPI_OK;
    
    NSMutableDictionary* headers = [[NSMutableDictionary alloc] initWithCapacity: headersCount ];
    
    for (i = 0; i < headersCount; i++)
    {
        char *tempBuffer;
        if (HTTPHeaders_GetHeader(httpHeadersHandle, i, &tempBuffer) != HTTP_HEADERS_OK)
        {
            /* error */
            result = HTTPAPI_HTTP_HEADERS_FAILED;
            LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, result));
            break;
        }
        else
        {
            // tempBuffer is in the form "name: value"
            NSString* rawNameVal = [NSString stringWithUTF8String: tempBuffer];
            NSArray*  nameVal = [rawNameVal componentsSeparatedByString: @": "];
            
            if( nameVal.count != 2 )
            {
                result = HTTPAPI_HTTP_HEADERS_FAILED;
                LogError("(Header name/value( %s ) poorly formed = %s)\r\n", tempBuffer, ENUM_TO_STRING(HTTPAPI_RESULT, result));
                break;
            }
            
            headers[ nameVal[0]] = nameVal[1];
        }
    }
    
    if( headers.count )
    {
        [osxHandle->config setHTTPAdditionalHeaders: headers];
        osxHandle->session = [NSURLSession sessionWithConfiguration: osxHandle->config delegate: nil delegateQueue: osxHandle->queue ];
    }
    
    return result;
}

/**
 * @brief   Sends the HTTP request to the host and handles the response for
 *          the HTTP call.
 *
 * @param   handle                  The handle to the HTTP connection created
 *                                  via ::HTTPAPI_CreateConnection.
 * @param   requestType             Specifies which HTTP method is used (GET,
 *                                  POST, DELETE, PUT, PATCH).
 * @param   relativePath            Specifies the relative path of the URL
 *                                  excluding the host name.
 * @param   httpHeadersHandle       Specifies a set of HTTP headers (name-value
 *                                  pairs) to be added to the
 *                                  HTTP request. The @p httpHeadersHandle
 *                                  handle can be created and setup with
 *                                  the proper name-value pairs by using the
 *                                  HTTPHeaders APIs available in @c
 *                                  HTTPHeaders.h.
 * @param   content                 Specifies a pointer to the request body.
 *                                  This value is optional and can be @c NULL.
 * @param   contentLength           Specifies the request body size (this is
 *                                  typically added into the HTTP headers as
 *                                  the Content-Length header). This value is
 *                                  optional and can be 0.
 * @param   statusCode              This is an out parameter, where
 *                                  ::HTTPAPI_ExecuteRequest returns the status
 *                                  code from the HTTP response (200, 201, 400,
 *                                  401, etc.)
 * @param   responseHeadersHandle   This is an HTTP headers handle to which
 *                                  ::HTTPAPI_ExecuteRequest must add all the
 *                                  HTTP response headers so that the caller of
 *                                  ::HTTPAPI_ExecuteRequest can inspect them.
 *                                  You can manipulate @p responseHeadersHandle
 *                                  by using the HTTPHeaders APIs available in
 *                                  @c HTTPHeaders.h
 * @param   responseContent         This is a buffer that must be filled by
 *                                  ::HTTPAPI_ExecuteRequest with the contents
 *                                  of the HTTP response body. The buffer size
 *                                  must be increased by the
 *                                  ::HTTPAPI_ExecuteRequest implementation in
 *                                  order to fit the response body.
 *                                  ::HTTPAPI_ExecuteRequest must also handle
 *                                  chunked transfer encoding for HTTP responses.
 *                                  To manipulate the @p responseContent buffer,
 *                                  use the APIs available in @c Strings.h.
 *
 * @return  @c HTTPAPI_OK if the API call is successful or an error
 *          code in case it fails.
 */
HTTPAPI_RESULT HTTPAPI_ExecuteRequest(HTTP_HANDLE handle, HTTPAPI_REQUEST_TYPE requestType, const char* relativePath,
                                             HTTP_HEADERS_HANDLE httpHeadersHandle, const unsigned char* content,
                                             size_t contentLength, unsigned int* statusCode,
                                             HTTP_HEADERS_HANDLE responseHeadersHandle, BUFFER_HANDLE responseContent)
{
    HTTP_HANDLE_OSX* osxHandle = (HTTP_HANDLE_OSX*)handle;
    __block HTTPAPI_RESULT result = HTTPAPI_OK;
    NSMutableURLRequest* request = nil;
    *statusCode = 200;
    
    result = validateExecRequestParms( osxHandle, relativePath, content, contentLength );
    if( result != HTTPAPI_OK)
    {
        LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, result));
        return HTTPAPI_INVALID_ARG;
    }
    
    //osxHandle->delegate->connectionData = [[NSMutableData alloc] init];
    
    request = createURLRequest( osxHandle, relativePath, requestType, content, contentLength );
    
    if( request == nil )
    {
        LogError( "( Unable to create NSURLRequest: %s", "createURLRequest returned nil");
        return HTTPAPI_INVALID_ARG;
    }
    
    result = setHeaderValues(osxHandle, httpHeadersHandle );
    if( result != HTTPAPI_OK)
    {
        LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, result));
        return HTTPAPI_INVALID_ARG;
    }
    
    void (^handler)(NSData *data,
                    NSURLResponse *response,
                    NSError *error) = ^(NSData *data,
                                        NSURLResponse *response,
                                        NSError *error)
    {
        if( error != nil )
        {
            LogError("Errored out: %s", [error.description UTF8String]);
        }
        else
        {
            *statusCode = (unsigned int)((NSHTTPURLResponse*)response).statusCode;
            if( data.length )
            {
                NSString* strData = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
                if (BUFFER_build(responseContent, (const unsigned char*)[strData UTF8String], strData.length ) != 0)
                {
                    result = HTTPAPI_INSUFFICIENT_RESPONSE_BUFFER;
                    LogError("(result = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, result));
                }
            }
        }
        
        g_ready.notify_all();
        return;
    };
    
    switch (requestType)
    {
        default:
            LogError("(Invalid HTTP request type = %s)\r\n", ENUM_TO_STRING(HTTPAPI_RESULT, HTTPAPI_INVALID_ARG));
            request = nil;
            break;
            
        case HTTPAPI_REQUEST_GET:
            [request setHTTPMethod: @"GET"];
            osxHandle->task = [osxHandle->session dataTaskWithRequest: request completionHandler: handler];
            break;
            
        case HTTPAPI_REQUEST_POST:
        {
            [request setHTTPMethod: @"POST"];
            createTaskWithData( osxHandle, request, content, contentLength, handler);
        }
            break;
            
        case HTTPAPI_REQUEST_PUT:
            [request setHTTPMethod: @"PUT"];
            createTaskWithData( osxHandle, request, content, contentLength, handler);
            break;
            
        case HTTPAPI_REQUEST_DELETE:
            [request setHTTPMethod: @"DELETE"];
            osxHandle->task = [osxHandle->session dataTaskWithRequest: request completionHandler: handler];
            break;
            
        case HTTPAPI_REQUEST_PATCH:
            [request setHTTPMethod: @"PATCH"];
            osxHandle->task = [osxHandle->session dataTaskWithRequest: request completionHandler: handler];
            break;
    }
    
    [osxHandle->task resume];
    
    std::unique_lock<std::mutex> ul( g_mutex );
    g_ready.wait(ul);
    
    return result;
}

/**
 * @brief   Sets the option named @p optionName bearing the value
 *          @p value for the HTTP_HANDLE @p handle.
 *
 * @param   handle      The handle to the HTTP connection created via
 *                      ::HTTPAPI_CreateConnection.
 * @param   optionName  A @c NULL terminated string representing the name
 *                      of the option.
 * @param   value       A pointer to the value for the option.
 *
 * @return  @c HTTPAPI_OK if initialization is successful or an error
 *          code in case it fails.
 */
HTTPAPI_RESULT HTTPAPI_SetOption(HTTP_HANDLE handle, const char* optionName, const void* value)
{
    return HTTPAPI_OK;
}

/**
 * @brief   Clones the option named @p optionName bearing the value @p value
 *          into the pointer @p savedValue.
 *
 * @param   optionName  A @c NULL terminated string representing the name of
 *                      the option
 * @param   value       A pointer to the value of the option.
 * @param   savedValue  This pointer receives the copy of the value of the
 *                      option. The copy needs to be free-able.
 *
 * @return  @c HTTPAPI_OK if initialization is successful or an error
 *          code in case it fails.
 */
HTTPAPI_RESULT HTTPAPI_CloneOption(const char* optionName, const void* value, const void** savedValue)
{
    return HTTPAPI_OK;
}