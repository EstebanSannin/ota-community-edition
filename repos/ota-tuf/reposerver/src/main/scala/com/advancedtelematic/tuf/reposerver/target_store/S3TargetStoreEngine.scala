package com.advancedtelematic.tuf.reposerver.target_store

import java.io.File
import java.net.URI
import java.time.temporal.ChronoUnit
import java.time.{Duration, Instant}
import java.util.Date

import scala.async.Async._
import scala.jdk.CollectionConverters._
import org.apache.pekko.Done
import org.apache.pekko.actor.ActorSystem
import org.apache.pekko.http.scaladsl.model.Uri
import org.apache.pekko.http.scaladsl.util.FastFuture
import org.apache.pekko.stream.scaladsl.{FileIO, Source, StreamConverters}
import org.apache.pekko.util.ByteString
import com.advancedtelematic.libtuf.data.TufDataType.{
  GetSignedUrlResult,
  InitMultipartUploadResult,
  MultipartUploadId,
  RepoId,
  TargetFilename,
  UploadPartETag
}
import com.advancedtelematic.tuf.reposerver.Settings
import com.advancedtelematic.tuf.reposerver.target_store.TargetStoreEngine.{
  TargetBytes,
  TargetRedirect,
  TargetRetrieveResult,
  TargetStoreResult
}
import com.amazonaws.HttpMethod
import com.amazonaws.auth.{
  AWSCredentials,
  AWSCredentialsProvider,
  DefaultAWSCredentialsProviderChain
}
import com.amazonaws.client.builder.AwsClientBuilder.EndpointConfiguration
import com.amazonaws.regions.Regions
import com.amazonaws.services.s3.{AmazonS3, AmazonS3ClientBuilder, Headers}
import com.amazonaws.services.s3.model.{
  CompleteMultipartUploadRequest,
  GeneratePresignedUrlRequest,
  InitiateMultipartUploadRequest,
  ObjectMetadata,
  PartETag,
  PutObjectRequest
}
import org.slf4j.LoggerFactory

import scala.concurrent._
import scala.concurrent.Future
import scala.util.Try

class S3TargetStoreEngine(credentials: S3Credentials)(implicit val system: ActorSystem)
    extends TargetStoreEngine
    with Settings {

  import system.dispatcher

  private val bucketId = credentials.bucketId

  private val log = LoggerFactory.getLogger(this.getClass)

  // Upstream: fall back to the DefaultAWSCredentialsProviderChain (IRSA / instance profile / env)
  // when no explicit access/secret key is configured.
  private val credentialsProvider =
    if (credentials.hasExplicitCredentials) {
      log.info("Using explicit AWS access/secret key credentials for S3")
      credentials
    } else {
      log.info(
        "No explicit AWS credentials configured, using DefaultAWSCredentialsProviderChain (supports IRSA/instance profile/env vars)"
      )
      DefaultAWSCredentialsProviderChain.getInstance()
    }

  private def s3ClientFor(endpoint: Option[String]): AmazonS3 = {
    val builder = AmazonS3ClientBuilder.standard().withCredentials(credentialsProvider)

    endpoint
      .map { url =>
        // S3-compatible store (MinIO and friends): talk to a fixed endpoint and keep the bucket
        // in the path - a virtual-host style `bucket.host` name would not resolve. Dualstack is
        // AWS-only and the SDK rejects it together with an explicit endpoint.
        builder
          .withEndpointConfiguration(new EndpointConfiguration(url, credentials.region.getName))
          .withPathStyleAccessEnabled(true)
      }
      .getOrElse(builder.withRegion(credentials.region).withDualstackEnabled(true))
      .build()
  }

  private lazy val s3client = s3ClientFor(credentials.endpointUrl)

  private val s3Compatible = credentials.endpointUrl.isDefined

  // Pre-signed URLs are handed out to clients that live outside our network, so they must be
  // signed for a host those clients can actually reach (the signature covers the Host header).
  // Everything else - putObject, getObject, initiate/complete multipart - is a server-side call
  // and goes to the internal endpoint.
  private lazy val signingClient =
    if (credentials.publicEndpointUrl.isEmpty)
      s3client
    else if (credentials.publicEndpointUrl == credentials.endpointUrl)
      s3client
    else
      s3ClientFor(credentials.publicEndpointUrl)

  override def store(repoId: RepoId,
                     filename: TargetFilename,
                     fileData: Source[ByteString, Any]): Future[TargetStoreResult] = {
    val tempFile = File.createTempFile("s3file", ".tmp")

    // The s3 sdk requires us to specify the file size if using a stream
    // so we always need to cache the file into the filesystem before uploading
    val sink = FileIO.toPath(tempFile.toPath).mapMaterializedValue {
      _.flatMap { _ =>
        upload(repoId, tempFile, filename).andThen { case _ => Try(tempFile.delete()) }
      }.recoverWith { case err =>
        Try(tempFile.delete())
        FastFuture.failed(err)
      }
    }

    write(fileData, sink)
  }

  override def storeStream(repoId: RepoId,
                           filename: TargetFilename,
                           fileData: Source[ByteString, Any],
                           size: Long): Future[TargetStoreResult] = {
    val storagePath = storageFilename(repoId, filename)
    val sink = StreamConverters.asInputStream().mapMaterializedValue { is =>
      val meta = new ObjectMetadata()
      meta.setContentLength(size)
      val request = new PutObjectRequest(bucketId, storagePath.toString, is, meta)

      log.info(s"Uploading $filename to amazon s3 using streaming upload")

      val uploadF = async {
        await(Future(blocking(s3client.putObject(request))))
        log.info(s"$filename with size $size uploaded to s3")
        await(Future(blocking(s3client.getUrl(bucketId, storagePath.toString))))
      }

      uploadF.map(uri => Uri(uri.toString) -> size)
    }

    write(fileData, sink)
  }

  protected def upload(repoId: RepoId,
                       file: File,
                       filename: TargetFilename): Future[(Uri, Long)] = {
    val storagePath = storageFilename(repoId, filename)
    val request = new PutObjectRequest(credentials.bucketId, storagePath.toString, file)

    log.info(s"Uploading ${filename.value} to amazon s3")

    async {
      await(Future(blocking(s3client.putObject(request))))
      val uri = await(Future(blocking(s3client.getUrl(bucketId, storagePath.toString))))
      val metadata = await(Future {
        blocking(s3client.getObjectMetadata(bucketId, storagePath.toString))
      })

      log.info(s"$filename uploaded to s3")

      (Uri(uri.toString), metadata.getContentLength)
    }
  }

  override def retrieve(repoId: RepoId, filename: TargetFilename): Future[TargetRetrieveResult] =
    if (credentials.endpointUrl.isDefined) retrieveBytes(repoId, filename)
    else {
      val storagePath = storageFilename(repoId, filename)
      val publicExpireTime = Duration.ofDays(1)
      val expire = java.util.Date.from(Instant.now.plus(publicExpireTime))
      Future {
        val signedUri = blocking {
          signingClient.generatePresignedUrl(bucketId, storagePath.toString, expire)
        }

        TargetRedirect(Uri(signedUri.toURI.toString))
      }
    }

  // Self-hosted object store: stream the bytes back through the reposerver rather than
  // redirecting the caller to the store. Devices then only ever talk to the OTA gateway - they
  // don't have to reach the object store or trust its TLS certificate, so switching storage
  // backends leaves the device-facing download path untouched.
  private def retrieveBytes(repoId: RepoId,
                            filename: TargetFilename): Future[TargetRetrieveResult] = {
    val storagePath = storageFilename(repoId, filename).toString

    Future {
      val obj = blocking(s3client.getObject(bucketId, storagePath))
      val size = obj.getObjectMetadata.getContentLength
      val bytes = StreamConverters
        .fromInputStream(() => obj.getObjectContent)
        .mapMaterializedValue(_ => FastFuture.successful(Done))

      TargetBytes(bytes, size)
    }
  }

  override def delete(repoId: RepoId, filename: TargetFilename): Future[Unit] = Future {
    blocking {
      val storagePath = storageFilename(repoId, filename)
      s3client.deleteObject(bucketId, storagePath.toString)
    }
  }

  override def buildStorageUri(repoId: RepoId,
                               filename: TargetFilename,
                               length: Long): Future[Uri] = {
    val objectId = storageFilename(repoId, filename).toString
    val expiresAt = Date.from(Instant.now().plus(3, ChronoUnit.HOURS))

    log.info(s"Signing s3 url for $objectId")

    FastFuture.successful {
      val req = new GeneratePresignedUrlRequest(bucketId, objectId, HttpMethod.PUT)
      if (!s3Compatible) req.putCustomRequestHeader("Content-Length", length.toString)
      req.setExpiration(expiresAt)
      val url = presign(req)
      log.debug(s"Signed s3 url for $objectId")
      url
    }
  }

  /* Sign a URL, and percent-encode the semicolons the AWS signer leaves raw in
   * X-Amz-SignedHeaders (`content-length;host`). AWS itself accepts them, but Go's net/url treats
   * a bare ';' in a query string as an error, so an S3-compatible store written in Go (MinIO)
   * rejects the request outright with "invalid semicolon separator in query". The encoding is
   * transparent to the signature: the server decodes the value before verifying it. */
  private def presign(req: GeneratePresignedUrlRequest): String =
    signingClient.generatePresignedUrl(req).toString.replace(";", "%3B")

  override def initiateMultipartUpload(
    repoId: RepoId,
    filename: TargetFilename): Future[InitMultipartUploadResult] = FastFuture {
    val objectId: String = storageFilename(repoId, filename).toString
    val req = new InitiateMultipartUploadRequest(bucketId, objectId)
    Try(s3client.initiateMultipartUpload(req))
      .map(rs =>
        InitMultipartUploadResult(MultipartUploadId(rs.getUploadId), multipartUploadPartSize)
      )
  }

  override def buildSignedURL(repoId: RepoId,
                              filename: TargetFilename,
                              uploadId: MultipartUploadId,
                              partNumber: String,
                              md5: String,
                              contentLength: Int): Future[GetSignedUrlResult] = FastFuture {
    val objectId: String = storageFilename(repoId, filename).toString
    val req = new GeneratePresignedUrlRequest(bucketId, objectId, HttpMethod.PUT)
    req.addRequestParameter("uploadId", uploadId.value)
    req.addRequestParameter("partNumber", partNumber)
    // Signing content-md5/content-length makes X-Amz-SignedHeaders a semicolon-separated list,
    // which a Go-based store rejects outright - see presign(). The client sends both headers
    // regardless, and S3 semantics still have the store verify Content-MD5 against the body when
    // the header is present, so dropping them from the *signature* keeps the integrity check.
    if (!s3Compatible) {
      req.setContentMd5(md5)
      req.putCustomRequestHeader(Headers.CONTENT_LENGTH, contentLength.toString)
    }
    Try(presign(req)).map(url => GetSignedUrlResult(new URI(url)))
  }

  override def completeMultipartUpload(repoId: RepoId,
                                       filename: TargetFilename,
                                       uploadId: MultipartUploadId,
                                       partETags: Seq[UploadPartETag]): Future[Unit] =
    FastFuture {
      val objectId: String = storageFilename(repoId, filename).toString
      val eTags = partETags.map(t => new PartETag(t.part, t.eTag.value))
      val req = new CompleteMultipartUploadRequest(bucketId, objectId, uploadId.value, eTags.asJava)
      Try(s3client.completeMultipartUpload(req))
    }

}

/**
 * `endpointUrl` points the client at an S3-compatible store instead of AWS (e.g. a self-hosted
 * MinIO); `publicEndpointUrl` is the address that same store is reachable at from outside, used
 * only when signing upload URLs. Both empty = plain AWS S3, exactly as before.
 */
class S3Credentials(accessKey: String,
                    secretKey: String,
                    val bucketId: String,
                    val region: Regions,
                    val endpointUrl: Option[String] = None,
                    val publicEndpointUrl: Option[String] = None)
    extends AWSCredentials
    with AWSCredentialsProvider {

  val hasExplicitCredentials: Boolean = accessKey.nonEmpty && secretKey.nonEmpty

  override def getAWSAccessKeyId: String = accessKey

  override def getAWSSecretKey: String = secretKey

  override def refresh(): Unit = ()

  override def getCredentials: AWSCredentials = this
}
